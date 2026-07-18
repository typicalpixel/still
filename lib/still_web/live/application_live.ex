defmodule StillWeb.ApplicationLive do
  @moduledoc """
  Application detail: deploy and rollback (header actions), a status summary
  (health, hosts, version, last deploy), the fleet (assign/unassign), deploy
  history, configuration and environment editing, lifecycle hooks, an audit
  history, and delete. Reloads on deploy/health, server connect/disconnect, and
  fleet changes.
  """

  use StillWeb, :live_view

  import StillWeb.ApplicationComponents
  import StillWeb.AuditComponents
  import StillWeb.DeploymentComponents
  import StillWeb.ServerComponents

  alias Still.Accounts.Scope
  alias Still.Applications
  alias Still.Applications.Hook
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Events
  alias Still.Fleet
  alias Still.Orchestrator
  alias Still.Status
  alias StillWeb.EnvRows

  @doc "Mounts the application detail for the given name and subscribes to live topics."
  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket) do
      Events.subscribe("events:lobby")
      Events.subscribe("servers:lobby")
      Events.subscribe("fleet:changes")
    end

    {:ok,
     socket
     |> assign(:name, name)
     |> assign(:page_title, name)
     |> assign_permissions()
     |> assign_initial_ui_state()
     |> load()}
  end

  @doc "Renders the application detail, or a not-found notice."
  @impl true
  def render(%{app: nil} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={@nav}
      active_nav={:applications}
      breadcrumbs={[%{label: "Applications", navigate: ~p"/applications"}, %{label: "Not found"}]}
    >
      <.header>Application not found</.header>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={@nav}
      active_nav={:applications}
      breadcrumbs={[%{label: "Applications", navigate: ~p"/applications"}, %{label: @app.name}]}
    >
      <.header>
        <span class="inline-flex items-center gap-2">
          {@app.name}<.application_display type={@app.type} />
        </span>
        <:subtitle>
          <span class="inline-flex flex-wrap items-baseline gap-x-5 gap-y-1">
            <span class="inline-flex items-baseline gap-1.5">
              <span class="text-paper-500 dark:text-ink-300">Version</span>
              <span class="mono font-medium text-paper-800 dark:text-ink-50">
                {common_version(@status)}
              </span>
            </span>
            <span :if={@app.domain} class="inline-flex items-baseline gap-1.5 text-paper-400 dark:text-ink-500">
              Domain <span class="mono">{@app.domain}</span>
            </span>
            <span class="inline-flex items-baseline gap-1.5 text-paper-400 dark:text-ink-500">
              Artifact <span class="mono">{artifact_label(@app.artifact_source.type)}</span>
            </span>
          </span>
        </:subtitle>
        <:actions>
          <span :if={not @has_servers} class="mr-1 text-[12.5px] text-paper-500 dark:text-ink-300">
            No servers assigned — assign one to enable these actions.
          </span>
          <button
            :if={@can_deploy and @app.maintenance}
            type="button"
            class="btn btn-sm btn-tide"
            phx-click="exit_maintenance"
          >
            Exit maintenance
          </button>
          <button
            :if={@can_deploy and !@app.maintenance}
            type="button"
            class="btn btn-sm btn-tide"
            phx-click="open_maintenance"
            disabled={not @has_servers}
          >
            Maintenance
          </button>
          <.link
            :if={@can_deploy and @app.type == :elixir_release}
            navigate={~p"/applications/#{@app.name}/console"}
            class="btn btn-sm btn-tide"
          >
            Console
          </.link>
          <button
            :if={@can_rollback}
            type="button"
            class="btn btn-sm btn-tide"
            phx-click="open_rollback"
            disabled={not @rollback_available}
          >
            Roll back
          </button>
          <button
            :if={@can_deploy and @app.type != :static_site}
            type="button"
            class="btn btn-sm btn-tide"
            phx-click="open_restart"
            disabled={not @restart_available}
          >
            Restart
          </button>
          <button
            :if={@can_deploy}
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="open_deploy"
            disabled={not @has_servers}
          >
            Deploy
          </button>
        </:actions>
      </.header>

      <div
        :if={@app.maintenance}
        class="mt-4 rounded-lg border border-rust-300 p-3 text-[13px] text-rust-700 dark:border-rust-700/60 dark:text-rust-300"
      >
        In maintenance — visitors get a 503 on <span class="mono">{@app.domain}</span>
        instead of the app.<span :if={@app.maintenance_message}> “{@app.maintenance_message}”</span>
      </div>

      <div class="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-4">
        <.stat_card label="State">
          <span class="inline-flex items-center gap-2 text-[13px]">
            <.status_dot status={health_dot(@health)} />{row_health_label(@health)}
          </span>
        </.stat_card>
        <.stat_card label="Hosts">
          <span class="text-2xl font-semibold tabular-nums">
            {live_count(@status)}<span class="text-base text-paper-400 dark:text-ink-500">/{length(@status.assigned)}</span>
          </span>
        </.stat_card>
        <.stat_card label="Version">
          <span class="text-2xl font-semibold">{common_version(@status)}</span>
        </.stat_card>
        <.stat_card label="Last deploy">
          <span class="text-[15px]">{relative_time(@last_deploy_at)}</span>
        </.stat_card>
      </div>

      <section class="mt-8">
        <.section_heading>
          Fleet
          <:actions>
            <button :if={@can_admin} type="button" class="btn btn-sm btn-tide" phx-click="open_assign">
              Assign server
            </button>
          </:actions>
        </.section_heading>
        <.app_fleet fleet={@fleet} can_admin={@can_admin} />
      </section>

      <section class="mt-8">
        <.section_heading>Deploy history</.section_heading>
        <.deploy_table deployments={@deployments} />
      </section>

      <section class="mt-8">
        <.section_heading>
          Configuration
          <:actions>
            <button :if={@can_admin} type="button" class="btn btn-sm btn-tide" phx-click="open_config">
              Edit
            </button>
          </:actions>
        </.section_heading>
        <.app_config app={@app} />
      </section>

      <section class="mt-8">
        <.section_heading>
          Environment
          <:actions>
            <button :if={@can_admin} type="button" class="btn btn-sm btn-tide" phx-click="open_env">Edit</button>
          </:actions>
        </.section_heading>
        <.app_env app={@app} />
      </section>

      <section class="mt-8">
        <.section_heading>
          Lifecycle hooks
          <:actions>
            <button :if={@can_admin} type="button" class="btn btn-sm btn-tide" phx-click="open_hook_create">
              Add hook
            </button>
          </:actions>
        </.section_heading>
        <.app_hooks hooks={@hooks} can_admin={@can_admin} />
      </section>

      <section :if={@can_admin} class="mt-8">
        <.section_heading>Audit history</.section_heading>
        <p class="mb-2 text-[12.5px] text-paper-500 dark:text-ink-300">
          Configuration changes, deploy lifecycle, and assignment edits scoped to this application.
        </p>
        <.audit_log
          events={@audit_events}
          expanded={@expanded}
          show_subject={false}
          empty="No audit events for this application yet."
        />
      </section>

      <section :if={@can_admin} class="mt-8">
        <h2 class="mb-2 text-[13px] font-semibold text-rust-700 dark:text-rust-300">
          Danger zone
        </h2>
        <div class="flex items-center justify-between gap-6 rounded-lg border border-rust-300 p-4 dark:border-rust-700/60">
          <div>
            <div class="text-[13px] text-paper-800 dark:text-ink-50">Delete application</div>
            <div class="text-[11.5px] text-paper-500 dark:text-ink-300">
              Removes it from the controller. Unassign its servers first.
            </div>
          </div>
          <button type="button" class="btn btn-sm btn-error" phx-click="open_delete">Delete</button>
        </div>
      </section>

      <.assign_server_dialog
        show={@assign_open}
        app_name={@app.name}
        servers={@eligible_servers}
        error={@assign_error}
      />
      <.unassign_dialog target={@unassign_target} error={@unassign_error} />
      <.app_edit_dialog show={@config_open} app={@app} error={@config_error} />
      <.app_env_dialog show={@env_open} app_name={@app.name} rows={@env_rows} error={@env_error} />
      <.hook_dialog
        show={@hook_open}
        editing={@hook_editing}
        form={@hook_form}
        event={@hook_event}
        available_events={@available_events}
        error={@hook_error}
      />
      <.hook_delete_dialog target={@hook_delete_target} error={@hook_delete_error} />
      <.deploy_dialog
        show={@deploy_open}
        app_name={@app.name}
        form={@deploy_form}
        error={@deploy_error}
      />
      <.rollback_dialog
        show={@rollback_open}
        app_name={@app.name}
        version={common_version(@status)}
        error={@rollback_error}
      />
      <.restart_dialog
        show={@restart_open}
        app_name={@app.name}
        version={common_version(@status)}
        error={@restart_error}
      />
      <.maintenance_dialog
        show={@maintenance_open}
        app_name={@app.name}
        message={@app.maintenance_message}
        error={@maintenance_error}
      />
      <.app_delete_dialog app={@app} show={@delete_open} error={@delete_error} />
    </Layouts.app>
    """
  end

  @doc "Reloads the application on deploy/health, server connect/disconnect, and fleet changes."
  @impl true
  def handle_info({:event_recorded, event}, socket) do
    {:noreply,
     if(event.type in [:deployment_updated, :health_transition], do: load(socket), else: socket)}
  end

  def handle_info({:server_connected, _payload}, socket), do: {:noreply, load(socket)}
  def handle_info({:server_disconnected, _payload}, socket), do: {:noreply, load(socket)}
  def handle_info(:fleet_changed, socket), do: {:noreply, load(socket)}

  @doc "Toggles audit-row detail and drives the delete-application dialog."
  @impl true
  def handle_event("toggle_audit", %{"id" => id}, socket) do
    {:noreply, update(socket, :expanded, &toggle_member(&1, id))}
  end

  def handle_event("open_delete", _params, socket),
    do:
      require_admin(
        socket,
        &{:noreply, &1 |> assign(:delete_open, true) |> assign(:delete_error, nil)}
      )

  def handle_event("close_delete", _params, socket),
    do: {:noreply, assign(socket, :delete_open, false)}

  def handle_event("delete_app", _params, socket),
    do: authorize_event(socket, :admin, &delete_app/1)

  def handle_event("open_assign", _params, socket),
    do:
      require_admin(
        socket,
        &{:noreply, &1 |> assign(:assign_open, true) |> assign(:assign_error, nil)}
      )

  def handle_event("close_assign", _params, socket),
    do: {:noreply, assign(socket, :assign_open, false)}

  def handle_event("assign_server", %{"server_id" => ""}, socket),
    do: require_admin(socket, &{:noreply, assign(&1, :assign_error, "Pick a server.")})

  def handle_event("assign_server", %{"server_id" => id}, socket) do
    with :ok <- require_permission(socket, :admin),
         server when not is_nil(server) <- Fleet.get_server(id) do
      assign_server(socket, server)
    else
      {:error, socket} -> {:noreply, socket}
      nil -> {:noreply, assign(socket, :assign_error, "Couldn't find that server.")}
    end
  end

  def handle_event("open_unassign", %{"id" => id, "name" => name}, socket) do
    require_admin(
      socket,
      &{:noreply,
       &1 |> assign(:unassign_target, %{id: id, name: name}) |> assign(:unassign_error, nil)}
    )
  end

  def handle_event("close_unassign", _params, socket),
    do: {:noreply, assign(socket, :unassign_target, nil)}

  def handle_event("unassign_server", _params, socket),
    do: authorize_event(socket, :admin, &unassign_server/1)

  def handle_event("open_config", _params, socket),
    do:
      require_admin(
        socket,
        &{:noreply, &1 |> assign(:config_open, true) |> assign(:config_error, nil)}
      )

  def handle_event("close_config", _params, socket),
    do: {:noreply, assign(socket, :config_open, false)}

  def handle_event("save_config", params, socket),
    do: authorize_event(socket, :admin, &save_config(&1, params))

  def handle_event("open_env", _params, socket),
    do: authorize_event(socket, :admin, &open_env/1)

  def handle_event("close_env", _params, socket),
    do: {:noreply, assign(socket, :env_open, false)}

  def handle_event("add_env_row", _params, socket),
    do:
      require_admin(
        socket,
        &{:noreply, update(&1, :env_rows, fn rows -> rows ++ [%{key: "", value: ""}] end)}
      )

  def handle_event("remove_env_row", %{"index" => index}, socket),
    do:
      require_admin(
        socket,
        &{:noreply,
         update(&1, :env_rows, fn rows -> List.delete_at(rows, String.to_integer(index)) end)}
      )

  def handle_event("validate_env", params, socket),
    do:
      require_admin(
        socket,
        &{:noreply, assign(&1, :env_rows, EnvRows.from_params(Map.get(params, "env", %{})))}
      )

  def handle_event("save_env", params, socket),
    do: authorize_event(socket, :admin, &validate_and_save_env(&1, params))

  def handle_event("open_hook_create", _params, socket),
    do: authorize_event(socket, :admin, &open_hook_create/1)

  def handle_event("open_hook_edit", %{"id" => id}, socket) do
    authorize_event(socket, :admin, fn socket ->
      hook = Applications.get_hook!(application_scope(socket), id)

      {:noreply,
       socket
       |> assign(:hook_open, true)
       |> assign(:hook_editing, hook)
       |> assign(:available_events, [])
       |> assign(:hook_error, nil)
       |> assign(
         :hook_form,
         hook_form(%{"script" => hook.script, "timeout_ms" => hook.timeout_ms})
       )}
    end)
  end

  def handle_event("close_hook", _params, socket),
    do: {:noreply, assign(socket, :hook_open, false)}

  def handle_event("select_hook_event", %{"event" => event}, socket),
    do: require_admin(socket, &{:noreply, assign(&1, :hook_event, event)})

  def handle_event("save_hook", %{"hook" => params}, socket) do
    authorize_event(socket, :admin, fn socket ->
      case socket.assigns.hook_editing do
        nil -> create_hook(socket, params)
        hook -> update_hook(socket, hook, params)
      end
    end)
  end

  def handle_event("open_hook_delete", %{"id" => id}, socket) do
    authorize_event(socket, :admin, fn socket ->
      {:noreply,
       socket
       |> assign(:hook_delete_target, Applications.get_hook!(application_scope(socket), id))
       |> assign(:hook_delete_error, nil)}
    end)
  end

  def handle_event("close_hook_delete", _params, socket),
    do: {:noreply, assign(socket, :hook_delete_target, nil)}

  def handle_event("delete_hook", _params, socket),
    do: authorize_event(socket, :admin, &delete_hook/1)

  def handle_event("open_deploy", _params, socket),
    do: authorize_event(socket, :deploy, &open_deploy/1)

  def handle_event("close_deploy", _params, socket),
    do: {:noreply, assign(socket, :deploy_open, false)}

  def handle_event("deploy", %{"deploy" => params}, socket),
    do: authorize_event(socket, :deploy, &deploy(&1, params))

  def handle_event("open_rollback", _params, socket) do
    authorize_event(socket, :rollback, fn socket ->
      {:noreply, socket |> assign(:rollback_open, true) |> assign(:rollback_error, nil)}
    end)
  end

  def handle_event("close_rollback", _params, socket),
    do: {:noreply, assign(socket, :rollback_open, false)}

  def handle_event("rollback", _params, socket),
    do: authorize_event(socket, :rollback, &rollback/1)

  def handle_event("open_restart", _params, socket),
    do:
      authorize_event(
        socket,
        :deploy,
        &{:noreply, &1 |> assign(:restart_open, true) |> assign(:restart_error, nil)}
      )

  def handle_event("close_restart", _params, socket),
    do: {:noreply, assign(socket, :restart_open, false)}

  def handle_event("restart", _params, socket),
    do: authorize_event(socket, :deploy, &restart/1)

  def handle_event("open_maintenance", _params, socket),
    do:
      authorize_event(
        socket,
        :deploy,
        &{:noreply, &1 |> assign(:maintenance_open, true) |> assign(:maintenance_error, nil)}
      )

  def handle_event("close_maintenance", _params, socket),
    do: {:noreply, assign(socket, :maintenance_open, false)}

  def handle_event("enter_maintenance", params, socket),
    do:
      authorize_event(
        socket,
        :deploy,
        &set_maintenance(&1, true, blank_to_nil(params["message"]))
      )

  def handle_event("exit_maintenance", _params, socket),
    do: authorize_event(socket, :deploy, &set_maintenance(&1, false, nil))

  defp delete_app(socket) do
    app = socket.assigns.app

    if Applications.application_has_assignments?(app.id) do
      {:noreply,
       assign(socket, :delete_error, "Unassign every server before deleting this application.")}
    else
      {:ok, _} =
        Applications.delete_application(Actor.from_scope(socket.assigns.current_scope), app)

      {:noreply,
       socket
       |> put_flash(:info, "#{app.name} deleted")
       |> push_navigate(to: ~p"/applications")}
    end
  end

  defp assign_server(socket, server) do
    case Applications.assign_server(current_actor(socket), socket.assigns.app, server) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign(:assign_open, false)
         |> load()
         |> put_flash(:info, "#{server.name} assigned")}

      {:error, _reason} ->
        {:noreply, assign(socket, :assign_error, "Couldn't assign that server.")}
    end
  end

  defp unassign_server(socket) do
    target = socket.assigns.unassign_target
    assignment = Applications.get_application_server!(application_scope(socket), target.id)
    {:ok, _} = Applications.unassign_server(current_actor(socket), assignment)

    {:noreply,
     socket
     |> assign(:unassign_target, nil)
     |> load()
     |> put_flash(:info, "#{target.name} unassigned")}
  end

  defp save_config(socket, params) do
    case Orchestrator.update_application(
           current_actor(socket),
           socket.assigns.app,
           config_attrs(params)
         ) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:config_open, false)
         |> load()
         |> put_flash(:info, "Configuration saved")}

      {:error, _changeset} ->
        {:noreply,
         assign(socket, :config_error, "Couldn't save — check the fields and try again.")}
    end
  end

  defp open_env(socket) do
    rows = EnvRows.to_rows(socket.assigns.app.env_vars)

    {:noreply,
     socket |> assign(:env_open, true) |> assign(:env_rows, rows) |> assign(:env_error, nil)}
  end

  defp validate_and_save_env(socket, params) do
    rows = EnvRows.from_params(Map.get(params, "env", %{}))

    case EnvRows.to_env_vars(rows) do
      {:ok, env} -> save_env(socket, env)
      {:error, message} -> {:noreply, assign(socket, :env_error, message)}
    end
  end

  defp open_hook_create(socket) do
    taken = MapSet.new(socket.assigns.hooks, &to_string(&1.event))
    available = Hook.events() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in taken))

    {:noreply,
     socket
     |> assign(:hook_open, true)
     |> assign(:hook_editing, nil)
     |> assign(:available_events, available)
     |> assign(:hook_event, List.first(available) || "pre_deploy")
     |> assign(:hook_error, nil)
     |> assign(:hook_form, hook_form(%{"script" => "", "timeout_ms" => 60_000}))}
  end

  defp delete_hook(socket) do
    target = socket.assigns.hook_delete_target
    {:ok, _} = Applications.delete_hook(current_actor(socket), target)

    {:noreply,
     socket
     |> assign(:hook_delete_target, nil)
     |> load()
     |> put_flash(:info, "#{target.event} hook deleted")}
  end

  defp open_deploy(socket) do
    {:noreply,
     socket
     |> assign(:deploy_open, true)
     |> assign(:deploy_error, nil)
     |> assign(:deploy_form, deploy_form())}
  end

  defp deploy(socket, params) do
    attrs = %{
      version: params["version"],
      artifact_url: params["artifact_url"],
      source: blank_to_nil(params["source"]),
      initiated_by: initiated_by(socket)
    }

    case Orchestrator.trigger_deployment(current_actor(socket), socket.assigns.app, attrs) do
      {:ok, deployment} ->
        {:noreply, push_navigate(socket, to: ~p"/deployments/#{deployment.id}")}

      {:error, :no_servers_assigned} ->
        {:noreply, assign(socket, :deploy_error, "Assign a server before deploying.")}

      {:error, _other} ->
        {:noreply,
         assign(
           socket,
           :deploy_error,
           "Couldn't start the deploy — check the version and artifact URL."
         )}
    end
  end

  defp set_maintenance(socket, enabled, message) do
    attrs = %{"maintenance" => enabled, "maintenance_message" => message}

    case Orchestrator.update_application(current_actor(socket), socket.assigns.app, attrs) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> assign(:maintenance_open, false)
         |> load()
         |> put_flash(:info, if(enabled, do: "Maintenance mode on", else: "Maintenance mode off"))}

      {:error, _changeset} ->
        {:noreply, assign(socket, :maintenance_error, "Couldn't update maintenance mode.")}
    end
  end

  defp rollback(socket) do
    case Orchestrator.trigger_rollback(current_actor(socket), socket.assigns.app, %{
           initiated_by: initiated_by(socket)
         }) do
      {:ok, deployment} ->
        {:noreply, push_navigate(socket, to: ~p"/deployments/#{deployment.id}")}

      {:error, _reason} ->
        {:noreply,
         assign(socket, :rollback_error, "No previous successful version to roll back to.")}
    end
  end

  defp restart(socket) do
    case Orchestrator.trigger_restart(current_actor(socket), socket.assigns.app, %{
           initiated_by: initiated_by(socket)
         }) do
      {:ok, deployment} ->
        {:noreply, push_navigate(socket, to: ~p"/deployments/#{deployment.id}")}

      {:error, _reason} ->
        {:noreply,
         assign(socket, :restart_error, "Couldn't restart — there's no current deployment.")}
    end
  end

  defp load(socket) do
    case Applications.get_application_by_name(socket.assigns.name) do
      nil ->
        assign(socket, :app, nil)

      app ->
        status = Enum.find(Status.applications_with_reports(), &(&1.application.name == app.name))
        servers = Fleet.list_servers()
        servers_by_id = Map.new(servers, &{&1.id, &1})

        assignment_ids =
          Map.new(Applications.list_application_servers(app), &{&1.server_id, &1.id})

        deployments = Deployments.list_deployments(%{application: app.name, limit: 20})
        has_servers = status.assigned != []

        socket
        |> assign(:app, app)
        |> assign(:status, status)
        |> assign(:has_servers, has_servers)
        |> assign(
          :rollback_available,
          has_servers and Deployments.get_rollback_target(app) != nil
        )
        |> assign(
          :restart_available,
          has_servers and Deployments.get_current_deployment(app) != nil
        )
        |> assign(:health, row_health(status))
        |> assign(:fleet, build_fleet(status, servers_by_id, assignment_ids))
        |> assign(:eligible_servers, eligible_servers(servers, status))
        |> assign(:hooks, Applications.list_hooks_for(app))
        |> assign(:deployments, deployments)
        |> assign(:last_deploy_at, deployments |> List.first() |> deploy_at())
        |> assign(:audit_events, load_audit(socket, app))
    end
  end

  defp load_audit(socket, app) do
    if socket.assigns.can_admin,
      do: Audit.list(%{subject_type: "application", subject_id: app.id, limit: 50}),
      else: []
  end

  defp assign_permissions(socket) do
    socket
    |> assign(:can_admin, Scope.can?(socket.assigns.current_scope, :admin))
    |> assign(:can_deploy, Scope.can?(socket.assigns.current_scope, :deploy))
    |> assign(:can_rollback, Scope.can?(socket.assigns.current_scope, :rollback))
  end

  defp assign_initial_ui_state(socket) do
    socket
    |> assign(:expanded, MapSet.new())
    |> assign(:delete_open, false)
    |> assign(:delete_error, nil)
    |> assign(:assign_open, false)
    |> assign(:assign_error, nil)
    |> assign(:unassign_target, nil)
    |> assign(:unassign_error, nil)
    |> assign(:config_open, false)
    |> assign(:config_error, nil)
    |> assign(:env_open, false)
    |> assign(:env_rows, [])
    |> assign(:env_error, nil)
    |> assign(:hook_open, false)
    |> assign(:hook_editing, nil)
    |> assign(:hook_event, nil)
    |> assign(:hook_error, nil)
    |> assign(:hook_form, hook_form(%{"script" => "", "timeout_ms" => 60_000}))
    |> assign(:available_events, [])
    |> assign(:hook_delete_target, nil)
    |> assign(:hook_delete_error, nil)
    |> assign(:deploy_open, false)
    |> assign(:deploy_error, nil)
    |> assign(:deploy_form, deploy_form())
    |> assign(:rollback_open, false)
    |> assign(:rollback_error, nil)
    |> assign(:restart_open, false)
    |> assign(:restart_error, nil)
    |> assign(:maintenance_open, false)
    |> assign(:maintenance_error, nil)
  end

  defp require_permission(socket, permission) do
    if Scope.can?(socket.assigns.current_scope, permission) do
      :ok
    else
      {:error,
       socket |> put_flash(:error, "#{permission_label(permission)} permission required.")}
    end
  end

  defp permission_label(:admin), do: "Admin"
  defp permission_label(:deploy), do: "Deploy"
  defp permission_label(:rollback), do: "Rollback"

  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp eligible_servers(servers, status) do
    assigned = MapSet.new(status.assigned, fn {row, _report, _live} -> row.server_id end)
    Enum.filter(servers, &("application" in &1.roles and &1.id not in assigned))
  end

  defp current_actor(socket), do: Actor.from_scope(socket.assigns.current_scope)

  defp application_scope(socket) do
    Scope.put_application(socket.assigns.current_scope, socket.assigns.app)
  end

  defp authorize_event(socket, permission, callback) when is_function(callback, 1) do
    case require_permission(socket, permission) do
      :ok -> callback.(socket)
      {:error, socket} -> {:noreply, socket}
    end
  end

  defp require_admin(socket, callback) when is_function(callback, 1) do
    case require_permission(socket, :admin) do
      :ok -> callback.(socket)
      {:error, socket} -> {:noreply, socket}
    end
  end

  defp config_attrs(params) do
    %{
      "domain" => params["domain"],
      "path_prefix" => blank_to_nil(params["path_prefix"]),
      "min_healthy" => params["min_healthy"],
      "artifact_source" => %{"type" => params["artifact_type"]}
    }
    |> maybe_put_exec(params)
    |> maybe_put_health(params)
  end

  defp maybe_put_exec(attrs, %{"exec_command" => exec} = params) do
    attrs
    |> Map.put("exec_command", exec)
    |> Map.put("exec_start_pre", blank_to_nil(params["exec_start_pre"]))
    |> Map.put("exec_stop", blank_to_nil(params["exec_stop"]))
    |> Map.put("exec_console", blank_to_nil(params["exec_console"]))
  end

  defp maybe_put_exec(attrs, _params), do: attrs

  defp maybe_put_health(attrs, %{"hc_path" => path} = params) do
    Map.put(attrs, "health_check", %{
      "path" => path,
      "interval_ms" => params["hc_interval"],
      "deadline_ms" => params["hc_deadline"]
    })
  end

  defp maybe_put_health(attrs, _params), do: attrs

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp save_env(socket, env) do
    {:ok, _} =
      Orchestrator.update_application(current_actor(socket), socket.assigns.app, %{
        "env_vars" => env
      })

    {:noreply,
     socket |> assign(:env_open, false) |> load() |> put_flash(:info, "Environment saved")}
  end

  defp create_hook(socket, params) do
    attrs = Map.put(params, "event", socket.assigns.hook_event)

    case Applications.create_hook(current_actor(socket), socket.assigns.app, attrs) do
      {:ok, _hook} ->
        {:noreply,
         socket |> assign(:hook_open, false) |> load() |> put_flash(:info, "Hook saved")}

      {:error, changeset} ->
        {:noreply, assign(socket, :hook_form, to_form(changeset, as: :hook))}
    end
  end

  defp update_hook(socket, hook, params) do
    case Applications.update_hook(current_actor(socket), hook, params) do
      {:ok, _hook} ->
        {:noreply,
         socket |> assign(:hook_open, false) |> load() |> put_flash(:info, "Hook saved")}

      {:error, changeset} ->
        {:noreply, assign(socket, :hook_form, to_form(changeset, as: :hook))}
    end
  end

  defp hook_form(attrs), do: to_form(attrs, as: :hook)

  defp deploy_form,
    do: to_form(%{"version" => "", "artifact_url" => "", "source" => ""}, as: :deploy)

  defp initiated_by(socket), do: "user:#{socket.assigns.current_scope.user.email}"

  defp artifact_label(:unauthenticated_url), do: "Public URL"
  defp artifact_label(:local_file), do: "Local file"

  defp build_fleet(status, servers_by_id, assignment_ids) do
    for {row, report, live} <- status.assigned do
      # An assignment's server can't be deleted (the delete path rejects it),
      # so the lookup always hits.
      server = Map.fetch!(servers_by_id, row.server_id)
      {health, current_version} = slot_status(live)

      %{
        assignment_id: Map.get(assignment_ids, row.server_id),
        server_id: row.server_id,
        server_name: server.name,
        host: server.host,
        desired_version: row.desired_version || "—",
        current_version: current_version,
        health: health,
        connected: report != nil,
        last_seen: server.last_seen_at
      }
    end
  end

  defp slot_status(nil), do: {nil, "—"}
  defp slot_status(live), do: {live.health, live.current_version || "—"}

  defp deploy_at(nil), do: nil
  defp deploy_at(%{inserted_at: at}), do: at
end
