defmodule Still.Deployments do
  @moduledoc """
  The Deployments context — deployment records and per-server step tracking.
  """

  import Ecto.Query, only: [from: 2]

  alias Still.Applications
  alias Still.Applications.Application
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Deployments.Deployment
  alias Still.Deployments.DeploymentStep
  alias Still.Repo

  @doc """
  Creates a deployment record and one `DeploymentStep` per assigned server, all
  wrapped in a transaction.

  Returns:

    * `{:ok, %Deployment{steps: [...]}}` on success, with steps preloaded
    * `{:error, :no_servers_assigned}` if the application has no assigned servers
    * `{:error, %Ecto.Changeset{}}` on validation failure
  """
  def create_deployment(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    case Applications.list_application_servers(application) do
      [] ->
        {:error, :no_servers_assigned}

      application_servers ->
        insert_deploy_with_steps(actor, application, application_servers, attrs)
    end
  end

  defp insert_deploy_with_steps(actor, application, application_servers, attrs) do
    deploy_changeset =
      %Deployment{}
      |> Deployment.creation_changeset(attrs)
      |> Ecto.Changeset.put_change(:application_id, application.id)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:deployment, deploy_changeset)
      |> Ecto.Multi.insert_all(:steps, DeploymentStep, fn %{deployment: deployment} ->
        build_step_rows(deployment, application_servers)
      end)
      |> Audit.multi(actor, fn %{deployment: deployment} ->
        [
          type: deploy_or_rollback_type(deployment),
          subject_type: :deployment,
          subject_id: deployment.id,
          payload: %{
            deployment_id: deployment.id,
            application_id: application.id,
            application_name: application.name,
            version: deployment.version,
            source: deployment.source,
            initiated_by: deployment.initiated_by
          },
          after: Audit.snapshot(deployment)
        ]
      end)

    case Repo.transact(multi) do
      {:ok, %{deployment: deployment, audit: event}} ->
        Audit.emit_live(event)
        {:ok, Repo.preload(deployment, :steps)}

      {:error, _name, %Ecto.Changeset{} = changeset, _changes_so_far} ->
        {:error, changeset}
    end
  end

  defp deploy_or_rollback_type(%Deployment{source: "rollback"}), do: :rollback_initiated
  defp deploy_or_rollback_type(%Deployment{}), do: :deploy_initiated

  @default_list_limit 50
  @max_list_limit 500

  @doc """
  Lists deployments, newest first. All filters are optional and combine
  with AND semantics. Accepts either a keyword list (for internal callers)
  or a map with string keys (for controller params).

    * `status` — one of the deployment statuses (atom or string)
    * `application` — an application name (string)
    * `server` — a server id (string). Matches deployments that have a
      step targeting this server.
    * `initiated_by` — exact-match actor string
    * `limit` — page size (1..500, default 50)
    * `before` — return deployments inserted strictly before this
      ISO-8601 timestamp (for keyset pagination)

  Preloads the parent `:application` so callers can render the application
  name without a second query per row.
  """
  def list_deployments(filters \\ %{})

  def list_deployments(filters) when is_map(filters) do
    limit = clamp_limit(fetch_filter(filters, :limit, @default_list_limit))

    Deployment
    |> apply_status_filter(fetch_filter(filters, :status))
    |> apply_application_filter(fetch_filter(filters, :application))
    |> apply_server_filter(fetch_filter(filters, :server))
    |> apply_initiated_by_filter(fetch_filter(filters, :initiated_by))
    |> apply_before_filter(fetch_filter(filters, :before))
    |> order_by_newest()
    |> limit_to(limit)
    |> preload_application()
    |> Repo.all()
  end

  def list_deployments(filters) when is_list(filters) do
    list_deployments(Map.new(filters))
  end

  defp fetch_filter(map, key, default \\ nil) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp clamp_limit(value) when is_integer(value), do: clamp_limit(value, 1, @max_list_limit)
  defp clamp_limit(value) when is_binary(value), do: parse_int_or_default(value)
  defp clamp_limit(_), do: @default_list_limit

  defp clamp_limit(value, min, max), do: value |> max(min) |> min(max)

  defp parse_int_or_default(value) do
    case Integer.parse(value) do
      {int, ""} -> clamp_limit(int, 1, @max_list_limit)
      _ -> @default_list_limit
    end
  end

  defp apply_status_filter(query, nil), do: query

  defp apply_status_filter(query, status) when is_binary(status) do
    case Enum.find(Deployment.statuses(), &(to_string(&1) == status)) do
      nil -> query
      atom -> apply_status_filter(query, atom)
    end
  end

  defp apply_status_filter(query, status) when is_atom(status) do
    from d in query, where: d.status == ^status
  end

  defp apply_application_filter(query, nil), do: query

  defp apply_application_filter(query, name) when is_binary(name) do
    from d in query,
      join: a in assoc(d, :application),
      where: a.name == ^name
  end

  defp apply_server_filter(query, nil), do: query

  defp apply_server_filter(query, server_id) when is_binary(server_id) do
    from d in query,
      join: s in DeploymentStep,
      on: s.deployment_id == d.id,
      where: s.server_id == ^server_id,
      distinct: true
  end

  defp apply_initiated_by_filter(query, nil), do: query

  defp apply_initiated_by_filter(query, actor) when is_binary(actor) do
    from d in query, where: d.initiated_by == ^actor
  end

  defp apply_before_filter(query, nil), do: query

  defp apply_before_filter(query, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> from d in query, where: d.inserted_at < ^dt
      _ -> query
    end
  end

  defp order_by_newest(query) do
    from d in query, order_by: [desc: d.inserted_at]
  end

  defp limit_to(query, n) do
    from d in query, limit: ^n
  end

  defp preload_application(query) do
    from d in query, preload: [:application]
  end

  @doc """
  Fetches a deployment by id, with `:steps` and `:application` preloaded.
  """
  def get_deployment!(id) when is_binary(id) do
    Deployment
    |> Repo.get!(id)
    |> Repo.preload([:steps, :application])
  end

  @doc """
  Fetches a deployment by id with `:steps` and `:application` preloaded, or
  `nil` when no deployment has that id.
  """
  def get_deployment(id) when is_binary(id) do
    case Repo.get(Deployment, id) do
      nil -> nil
      deployment -> Repo.preload(deployment, [:steps, :application])
    end
  end

  @doc """
  Lists all deployment steps for the given deployment, ordered by insertion time.
  """
  def list_deployment_steps_for(%Deployment{} = deployment) do
    Repo.all(
      from s in DeploymentStep,
        where: s.deployment_id == ^deployment.id,
        order_by: s.inserted_at
    )
  end

  @doc """
  Fetches a deployment step by id.
  """
  def get_deployment_step!(id) when is_binary(id) do
    Repo.get!(DeploymentStep, id)
  end

  @doc """
  Estimated completion timestamp for an in-flight deployment. Returns a
  `DateTime` when an estimate can be produced, `nil` when the deploy is
  already terminal or when there's no history to estimate from.

  Calculates `remaining_steps * average_step_duration`, where the
  average is computed from per-step durations in the most recent
  completed deploys of the same application.
  """
  def eta_at(%Deployment{status: status}) when status in [:completed, :failed, :rolled_back],
    do: nil

  def eta_at(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:steps, :application])
    progress = Deployment.progress(deployment)
    remaining = progress.total_steps - progress.completed_steps

    case average_step_duration_ms(deployment.application) do
      nil -> nil
      avg_ms -> DateTime.add(DateTime.utc_now(), remaining * avg_ms, :millisecond)
    end
  end

  @doc """
  Fetches progress + ETA for a deployment id without requiring the
  caller to preload. Convenience for the orchestrator to enrich
  `deployment_updated` broadcasts on each step transition.
  """
  def progress_and_eta_for(deployment_id) when is_binary(deployment_id) do
    deployment = get_deployment!(deployment_id)

    %{
      progress: Deployment.progress(deployment),
      eta_at: eta_at(deployment)
    }
  end

  # Average per-step duration across the last N successful deploys for
  # the given application. Returns `nil` when there's no history.
  @recent_step_sample 50

  defp average_step_duration_ms(%Still.Applications.Application{id: app_id}) do
    pairs =
      Repo.all(
        from s in DeploymentStep,
          join: d in Deployment,
          on: d.id == s.deployment_id,
          where: d.application_id == ^app_id and d.status == :completed,
          where: not is_nil(s.started_at) and not is_nil(s.completed_at),
          order_by: [desc: d.completed_at],
          limit: ^@recent_step_sample,
          select: {s.started_at, s.completed_at}
      )

    case pairs do
      [] ->
        nil

      pairs ->
        total =
          Enum.reduce(pairs, 0, fn {started, completed}, acc ->
            acc + DateTime.diff(completed, started, :millisecond)
          end)

        div(total, length(pairs))
    end
  end

  @doc """
  Marks a deployment as in-progress and records the start time.
  """
  def start_deployment!(%Deployment{} = deployment) do
    deployment
    |> Ecto.Changeset.change(%{status: :in_progress, started_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  @doc """
  Marks a deployment as completed and records the completion time.
  """
  def complete_deployment!(%Deployment{} = deployment) do
    deployment
    |> Ecto.Changeset.change(%{status: :completed, completed_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  @doc """
  Marks a deployment as failed and records the completion time. An
  optional `reason` is written to the `:error` field so operators can
  see why at a glance; pass `nil` when the cause is already captured
  on a child step.
  """
  def fail_deployment!(%Deployment{} = deployment, reason \\ nil)
      when is_nil(reason) or is_binary(reason) do
    deployment
    |> Ecto.Changeset.change(%{
      status: :failed,
      error: reason,
      completed_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  @doc """
  Marks every `:in_progress` deployment as `:failed` and every of its non-terminal
  steps as `:failed` with the given `reason` in the step's `error` field. Intended
  to be called once on controller boot to recover from a crash that left deploys
  orphaned. Returns `{deployments_updated, steps_updated}`.
  """
  def mark_orphaned_as_failed!(reason) when is_binary(reason) do
    now = DateTime.utc_now()

    orphaned_ids =
      Repo.all(from d in Deployment, where: d.status == :in_progress, select: d.id)

    case orphaned_ids do
      [] ->
        {0, 0}

      ids ->
        {deployments_updated, _} =
          from(d in Deployment, where: d.id in ^ids)
          |> Repo.update_all(
            set: [status: :failed, error: reason, completed_at: now, updated_at: now]
          )

        {steps_updated, _} =
          from(s in DeploymentStep,
            where: s.deployment_id in ^ids and s.status not in [:completed, :failed]
          )
          |> Repo.update_all(
            set: [status: :failed, error: reason, completed_at: now, updated_at: now]
          )

        {deployments_updated, steps_updated}
    end
  end

  @doc """
  Marks a deployment step as in-flight and records the start time.
  Called by the orchestrator just before handing the spec to the agent.
  """
  def start_deployment_step!(%DeploymentStep{} = step) do
    step
    |> Ecto.Changeset.change(%{started_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  @doc """
  Marks a deployment step as completed.
  """
  def complete_deployment_step!(%DeploymentStep{} = step) do
    step
    |> Ecto.Changeset.change(%{status: :completed, completed_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  @doc """
  Marks a deployment step as failed with the given error message.
  """
  def fail_deployment_step!(%DeploymentStep{} = step, error) when is_binary(error) do
    step
    |> Ecto.Changeset.change(%{status: :failed, error: error, completed_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  @doc """
  Fetches the deployment step for a specific server within a deployment.
  """
  def get_step_for_server!(deployment_id, server_id)
      when is_binary(deployment_id) and is_binary(server_id) do
    Repo.get_by!(DeploymentStep, deployment_id: deployment_id, server_id: server_id)
  end

  @doc """
  Returns the deployment the fleet would roll back to — the previous
  successful version. Returns `nil` when there is nothing to roll back to:
  fewer than two successful deployments, or the current live deployment is
  itself a rollback. Rollback is strictly one step back, so a second
  consecutive rollback has no target rather than bouncing onto the version
  the first rollback just escaped.
  """
  def get_rollback_target(%Application{} = application) do
    Repo.all(
      from d in Deployment,
        where: d.application_id == ^application.id and d.status == :completed,
        order_by: [desc: d.completed_at],
        limit: 2
    )
    |> case do
      # Current live deployment is already a rollback — nothing further back.
      # Without this, the `previous` below is the version that rollback escaped,
      # so a second consecutive rollback would bounce straight back onto it.
      [%Deployment{source: "rollback"} | _] -> nil
      [_current, %Deployment{} = previous] -> previous
      _ -> nil
    end
  end

  defp build_step_rows(deployment, application_servers) do
    now = DateTime.utc_now()

    Enum.map(application_servers, fn as ->
      %{
        id: Ecto.UUID.generate(),
        deployment_id: deployment.id,
        server_id: as.server_id,
        status: :pending,
        error: nil,
        started_at: nil,
        completed_at: nil,
        inserted_at: now,
        updated_at: now
      }
    end)
  end
end
