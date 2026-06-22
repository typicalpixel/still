defmodule Still.Orchestrator do
  @moduledoc """
  Rolling deployment coordinator.

  Accepts deployment requests, validates preconditions (servers assigned, enough
  agents connected), creates the database records, and spawns a background task
  that sends `{:deploy, spec}` to each agent server-by-server, halting on the
  first failure.

  Only one deployment per application may be in progress at a time — a second
  request for the same application returns `{:error, :deployment_in_progress}`.

  The actual agent call is injectable via the `:agent_caller` start option so
  tests can stub it without real Erlang distribution. An optional `:notifier`
  pid receives `{:deployment_complete, deployment_id, status}` when the
  background task finishes — used by tests to avoid `Process.sleep`.
  """

  use GenServer

  require Logger

  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Applications.Application
  alias Still.ArtifactStore
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Deployments.FailureReason
  alias Still.Protocol.DeployRequest

  # Fire-and-forget deploy/route tasks run under this supervisor (started in
  # Still.Application.common_children) so a crashing task can't take the
  # Orchestrator — or sibling deploys that used to share its link — down.
  @task_supervisor Still.Orchestrator.TaskSupervisor

  @doc """
  Starts the Orchestrator GenServer.

  Options:
    * `:agent_caller` — 2-arity fn `(node, %DeployRequest{}) -> {:ok, version} | {:error, reason}`
      used for `trigger_deployment/2`
    * `:rollback_agent_caller` — 2-arity fn with the same shape, used for
      `trigger_rollback/2`. The agent interprets the same struct as a rollback.
    * `:restart_agent_caller` — 2-arity fn with the same shape, used for
      `trigger_restart/2`. The agent interprets the same struct as a restart.
    * `:artifact_stager` — 2-arity fn `(application, deployment) -> :ok | {:error, reason}`
      that stages the artifact on the controller before fanning out to agents.
      Defaults to `&default_artifact_stager/2` which downloads via the
      application's artifact provider and caches locally.
    * `:notifier` — pid to receive `{:deployment_complete, id, :completed | :failed}`
      after either a deploy or a rollback finishes.
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers a deployment. Returns `{:ok, %Deployment{}}` immediately — the
  rolling sequence runs in a background task.
  """
  def trigger_deployment(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    GenServer.call(__MODULE__, {:trigger_deployment, actor, application, attrs})
  end

  @doc """
  Triggers a rollback. Creates a new deployment row that records the
  rollback target (the previous successful version), then calls each
  agent's `{:rollback, spec}` handler server-by-server. Returns
  `{:ok, %Deployment{}}` on accept, `{:error, :no_rollback_target}` if
  there is no prior successful deployment to roll back to, or any of the
  same preconditions as `trigger_deployment/2`.
  """
  def trigger_rollback(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    GenServer.call(__MODULE__, {:trigger_rollback, actor, application, attrs})
  end

  @doc """
  Triggers a restart. Creates a new deployment row pinned to the application's
  current live version, then calls each agent's `{:restart, spec}` handler
  server-by-server — re-booting that version into the standby slot, health-
  checking it, then cutting traffic over. Returns `{:ok, %Deployment{}}` on
  accept, `{:error, :not_deployed}` when the application has never deployed
  successfully, `{:error, :unsupported_for_type}` for a static site, or any of
  the same preconditions as `trigger_deployment/2`.
  """
  def trigger_restart(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    GenServer.call(__MODULE__, {:trigger_restart, actor, application, attrs})
  end

  @doc """
  Updates an application's mutable fields, then reconciles the serving Caddy
  route on each hosting agent when `domain` or `path_prefix` changed.

  Route reconciliation is best-effort and runs in the background:
  disconnected agents are skipped and pick up the change on their next
  deploy. Returns `{:ok, %Application{}}` or the changeset error.
  """
  def update_application(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    with {:ok, updated} <- Applications.update_application(actor, application, attrs) do
      if routing_changed?(application, updated), do: reconcile_app_routes(updated)
      {:ok, updated}
    end
  end

  @doc """
  Pushes a route-only reconcile to every agent hosting a live deployment of
  `application`, rebuilding its `still_app_*` route from the current
  domain/path_prefix and active slot. Returns `:ok` immediately; the
  fan-out runs in the background. No-op when the orchestrator worker isn't
  running (e.g. tests that exercise the controller without it).
  """
  def reconcile_app_routes(%Application{} = application) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:reconcile_routes, application})
    else
      :ok
    end
  end

  @impl true
  def init(opts) when is_list(opts) do
    unless Keyword.get(opts, :skip_orphan_recovery, false) do
      recover_orphans()
    end

    {:ok,
     %{
       in_progress: MapSet.new(),
       agent_caller: Keyword.get(opts, :agent_caller, &default_agent_caller/2),
       rollback_agent_caller:
         Keyword.get(opts, :rollback_agent_caller, &default_rollback_caller/2),
       restart_agent_caller: Keyword.get(opts, :restart_agent_caller, &default_restart_caller/2),
       route_caller: Keyword.get(opts, :route_caller, &default_route_caller/2),
       artifact_stager: Keyword.get(opts, :artifact_stager, &default_artifact_stager/2),
       notifier: Keyword.get(opts, :notifier)
     }}
  end

  defp recover_orphans do
    case Deployments.mark_orphaned_as_failed!("controller_restart") do
      {0, 0} ->
        :ok

      {deployments, steps} ->
        Logger.warning(
          "recovered #{deployments} orphaned deployment(s) and #{steps} step(s) " <>
            "left in_progress from a previous controller run"
        )
    end
  end

  @impl true
  def handle_call({:trigger_deployment, actor, application, attrs}, _from, state)
      when is_map(state) do
    if MapSet.member?(state.in_progress, application.name) do
      {:reply, {:error, :deployment_in_progress}, state}
    else
      case validate_and_create(actor, application, attrs) do
        {:ok, deployment, servers} ->
          state = %{state | in_progress: MapSet.put(state.in_progress, application.name)}

          spawn_rolling_task(
            deployment,
            application,
            servers,
            state.agent_caller,
            state.artifact_stager,
            state.notifier
          )

          {:reply, {:ok, deployment}, state}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:trigger_rollback, actor, application, attrs}, _from, state)
      when is_map(state) do
    if MapSet.member?(state.in_progress, application.name) do
      {:reply, {:error, :deployment_in_progress}, state}
    else
      case validate_and_create_rollback(actor, application, attrs) do
        {:ok, deployment, servers} ->
          state = %{state | in_progress: MapSet.put(state.in_progress, application.name)}

          spawn_rolling_task(
            deployment,
            application,
            servers,
            state.rollback_agent_caller,
            state.artifact_stager,
            state.notifier
          )

          {:reply, {:ok, deployment}, state}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:trigger_restart, actor, application, attrs}, _from, state)
      when is_map(state) do
    if MapSet.member?(state.in_progress, application.name) do
      {:reply, {:error, :deployment_in_progress}, state}
    else
      case validate_and_create_restart(actor, application, attrs) do
        {:ok, deployment, servers} ->
          state = %{state | in_progress: MapSet.put(state.in_progress, application.name)}

          spawn_rolling_task(
            deployment,
            application,
            servers,
            state.restart_agent_caller,
            state.artifact_stager,
            state.notifier
          )

          {:reply, {:ok, deployment}, state}

        {:error, _} = error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:reconcile_routes, application}, _from, state) when is_map(state) do
    route_caller = state.route_caller

    Task.Supervisor.start_child(@task_supervisor, fn ->
      reconcile_routes(application, route_caller)
    end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:deployment_finished, app_name}, state) when is_map(state) do
    {:noreply, %{state | in_progress: MapSet.delete(state.in_progress, app_name)}}
  end

  defp routing_changed?(before, updated) do
    before.domain != updated.domain or before.path_prefix != updated.path_prefix or
      before.maintenance != updated.maintenance or
      before.maintenance_message != updated.maintenance_message
  end

  # Fans the route-only spec out to each hosting agent, skipping servers
  # whose agent isn't currently connected.
  defp reconcile_routes(application, route_caller) do
    spec = route_spec(application)

    application
    |> Applications.list_application_servers()
    |> Enum.each(fn application_server ->
      case AgentConnectionManager.get_agent_state(application_server.server_id) do
        %{node: node} -> route_caller.(node, spec)
        nil -> :ok
      end
    end)
  end

  defp route_spec(application) do
    %{
      application: application.name,
      type: application.type,
      domain: application.domain,
      path_prefix: application.path_prefix,
      maintenance: application.maintenance,
      maintenance_message: application.maintenance_message
    }
  end

  defp validate_and_create(actor, application, attrs) do
    servers = Applications.list_application_servers(application)
    check_preconditions_and_create(actor, application, servers, attrs)
  end

  defp validate_and_create_rollback(actor, application, attrs) do
    case Deployments.get_rollback_target(application) do
      nil ->
        {:error, :no_rollback_target}

      %{version: version, artifact_url: artifact_url} ->
        attrs =
          attrs
          |> Map.put_new(:source, "rollback")
          |> Map.merge(%{version: version, artifact_url: artifact_url})

        validate_and_create(actor, application, attrs)
    end
  end

  # Static sites have no process to re-boot, so reject before creating a row or
  # calling any agent (the agent's restart step provider would have no list to
  # run). The current live version's row supplies a real version/artifact_url to
  # stamp the restart record with; the agent re-boots its own on-disk current.
  defp validate_and_create_restart(_actor, %Application{type: :static_site}, _attrs) do
    {:error, :unsupported_for_type}
  end

  defp validate_and_create_restart(actor, application, attrs) do
    case Deployments.get_current_deployment(application) do
      nil ->
        {:error, :not_deployed}

      %{version: version, artifact_url: artifact_url} ->
        attrs =
          attrs
          |> Map.put_new(:source, "restart")
          |> Map.merge(%{version: version, artifact_url: artifact_url})

        validate_and_create(actor, application, attrs)
    end
  end

  defp check_preconditions_and_create(_actor, _application, [], _attrs) do
    {:error, :no_servers_assigned}
  end

  defp check_preconditions_and_create(actor, application, servers, attrs) do
    connected = Enum.count(servers, &AgentConnectionManager.connected?(&1.server_id))

    if connected < application.min_healthy do
      {:error, :insufficient_healthy_agents}
    else
      case Deployments.create_deployment(actor, application, attrs) do
        {:ok, deployment} -> {:ok, deployment, servers}
        {:error, _} = error -> error
      end
    end
  end

  defp spawn_rolling_task(
         deployment,
         application,
         servers,
         agent_caller,
         artifact_stager,
         notifier
       ) do
    orchestrator = self()

    Task.Supervisor.start_child(@task_supervisor, fn ->
      status = run_deploy_safely(deployment, application, servers, agent_caller, artifact_stager)

      GenServer.cast(orchestrator, {:deployment_finished, application.name})
      if notifier, do: send(notifier, {:deployment_complete, deployment.id, status})
    end)
  end

  # The deploy task is unlinked (it runs under @task_supervisor), but an
  # unhandled crash mid-deploy — a `!` Repo call on a locked DB, an :exit from a
  # remote GenServer.call to a node that just died — would still skip the
  # `deployment_finished` cast and leave the app wedged in_progress. Convert any
  # crash into a failed deployment so the cast and notifier always run.
  defp run_deploy_safely(deployment, application, servers, agent_caller, artifact_stager) do
    execute_rolling_deploy(deployment, application, servers, agent_caller, artifact_stager)
  rescue
    exception -> fail_crashed(deployment, application, Exception.message(exception))
  catch
    kind, reason -> fail_crashed(deployment, application, "#{kind} #{inspect(reason)}")
  end

  defp fail_crashed(deployment, application, message) do
    Logger.error("deployment #{deployment.id} (#{application.name}) crashed: #{message}")
    failed = Deployments.fail_deployment!(deployment, message)
    record_terminal_audit(application, failed, :failed, message)
    broadcast_update(application, deployment, %{status: :failed, error: message})
    :failed
  end

  defp execute_rolling_deploy(deployment, application, servers, agent_caller, artifact_stager) do
    deployment = Deployments.start_deployment!(deployment)

    # six:ignore:start
    result =
      with :ok <- stage_artifact(application, deployment, artifact_stager) do
        Enum.reduce_while(servers, :ok, fn as, :ok ->
          deploy_to_server(deployment, application, as, agent_caller)
        end)
      end

    # six:ignore:stop

    case result do
      :ok ->
        completed = Deployments.complete_deployment!(deployment)
        record_terminal_audit(application, completed, :completed, nil)
        broadcast_update(application, deployment, %{status: :completed})
        :completed

      {:error, reason} ->
        error = format_reason(reason)

        Logger.warning(
          "deployment #{deployment.id} (#{application.name} #{deployment.version}) failed: #{error}"
        )

        failed = Deployments.fail_deployment!(deployment, error)
        record_terminal_audit(application, failed, :failed, error)
        broadcast_update(application, deployment, %{status: :failed, error: error})
        :failed
    end
  end

  # Audits a deploy's terminal transition. The actor is :system because
  # the orchestrator's background task — not the user who initiated —
  # decided the outcome. The deployment row's `subject_id` ties this
  # event to the earlier `:deploy_initiated` actor for a full timeline.
  defp record_terminal_audit(application, deployment, status, error) do
    type =
      case {status, deployment.source} do
        {:completed, "rollback"} -> :rollback_completed
        {:completed, "restart"} -> :restart_completed
        {:completed, _} -> :deploy_completed
        {:failed, "rollback"} -> :rollback_failed
        {:failed, "restart"} -> :restart_failed
        {:failed, _} -> :deploy_failed
      end

    {:ok, _} =
      Audit.record(Actor.system(),
        type: type,
        subject_type: :deployment,
        subject_id: deployment.id,
        payload:
          Map.reject(
            %{
              deployment_id: deployment.id,
              application_id: application.id,
              application_name: application.name,
              version: deployment.version,
              error: error
            },
            fn {_k, v} -> is_nil(v) end
          )
      )

    :ok
  end

  defp stage_artifact(application, deployment, artifact_stager) do
    case artifact_stager.(application, deployment) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.warning(
          "artifact staging failed for deployment #{deployment.id} " <>
            "(#{application.name} #{deployment.version}, url=#{deployment.artifact_url}): " <>
            format_reason(reason)
        )

        err
    end
  end

  defp format_reason(reason), do: FailureReason.headline(reason)

  defp deploy_to_server(deployment, application, application_server, agent_caller) do
    step = Deployments.get_step_for_server!(deployment.id, application_server.server_id)
    spec = build_deploy_request(application, deployment, application_server)

    case AgentConnectionManager.get_agent_state(application_server.server_id) do
      nil ->
        fail_step(deployment, application, application_server, step, :agent_disconnected)

      %{node: node} ->
        step = Deployments.start_deployment_step!(step)

        case agent_caller.(node, spec) do
          {:ok, _version} ->
            complete_step(deployment, application, application_server, step)

          {:error, reason} ->
            fail_step(deployment, application, application_server, step, reason)
        end
    end
  end

  defp complete_step(deployment, application, application_server, step) do
    Deployments.complete_deployment_step!(step)

    # Stamp desired_version per-server, on success only. Setting it fleet-wide up
    # front made servers that failed (or were never reached) keep desired=new
    # while running old — permanent phantom "drift" the reconciliation loop logs
    # forever on an otherwise-healthy fleet.
    _ = Applications.set_desired_version(application_server, deployment.version)

    broadcast_update(application, deployment, %{
      server_id: application_server.server_id,
      step_status: :completed
    })

    {:cont, :ok}
  end

  defp fail_step(deployment, application, application_server, step, reason) do
    error = format_reason(reason)

    Logger.warning(
      "deployment #{deployment.id} step on server #{application_server.server_id} " <>
        "(#{application.name} #{deployment.version}) failed: #{error}"
    )

    Deployments.fail_deployment_step!(step, error)

    broadcast_update(application, deployment, %{
      server_id: application_server.server_id,
      step_status: :failed,
      error: error
    })

    {:halt, {:error, error}}
  end

  # Wraps Still.Events.deployment_updated with the fields every push
  # needs (deployment_id, progress, eta_at) so the dashboard can update
  # a progress bar without refetching.
  defp broadcast_update(application, deployment, extra) when is_map(extra) do
    %{progress: progress, eta_at: eta_at} =
      Deployments.progress_and_eta_for(deployment.id)

    payload =
      Map.merge(extra, %{
        deployment_id: deployment.id,
        progress: progress,
        eta_at: eta_at
      })

    Still.Events.deployment_updated(application.name, payload)
  end

  defp build_deploy_request(application, deployment, application_server) do
    %DeployRequest{
      application: application.name,
      type: application.type,
      version: deployment.version,
      artifact_url: ArtifactStore.artifact_url(application.name, deployment.version),
      deployment_id: deployment.id,
      domain: application.domain,
      path_prefix: application.path_prefix,
      env_vars: application.env_vars,
      exec_command: application.exec_command,
      exec_start_pre: application.exec_start_pre,
      exec_stop: application.exec_stop,
      health_check: application.health_check,
      hooks: hooks_for(application),
      port_blue: application_server.port_blue,
      port_green: application_server.port_green
    }
  end

  # Turn the application's hook rows into the map the agent's
  # DeploymentManager consumes: `%{pre_deploy: %{script: ..., timeout_ms: ...}, ...}`.
  # Keyed by event atom so the agent can look up hooks by the step name
  # it's running without scanning a list.
  defp hooks_for(application) do
    application
    |> Applications.list_hooks_for()
    |> Map.new(fn hook ->
      {hook.event, %{script: hook.script, timeout_ms: hook.timeout_ms}}
    end)
  end

  # six:ignore:start
  defp default_artifact_stager(application, deployment) do
    source_type = application.artifact_source.type
    spec = %{artifact_url: deployment.artifact_url}

    case ArtifactStore.stage(application.name, deployment.version,
           source_type: source_type,
           spec: spec
         ) do
      {:ok, _path} ->
        ArtifactStore.prune(application.name)
        :ok

      {:error, reason} ->
        {:error, "artifact staging failed: #{inspect(reason)}"}
    end
  end

  defp default_agent_caller(node, spec) when is_atom(node) do
    GenServer.call(
      {Still.Agent.DeploymentManager, node},
      {:deploy, spec},
      120_000
    )
  end

  defp default_rollback_caller(node, spec) when is_atom(node) do
    GenServer.call(
      {Still.Agent.DeploymentManager, node},
      {:rollback, spec},
      120_000
    )
  end

  defp default_restart_caller(node, spec) when is_atom(node) do
    GenServer.call(
      {Still.Agent.DeploymentManager, node},
      {:restart, spec},
      120_000
    )
  end

  defp default_route_caller(node, spec) when is_atom(node) do
    GenServer.call(
      {Still.Agent.DeploymentManager, node},
      {:reconcile_route, spec},
      30_000
    )
  end

  # six:ignore:stop
end
