defmodule Still.Applications do
  @moduledoc """
  The Applications context — application registration, lookup, lifecycle, and
  server assignment.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Still.Accounts.Scope
  alias Still.Applications.Application
  alias Still.Applications.ApplicationServer
  alias Still.Applications.Hook
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Events
  alias Still.Fleet.Server
  alias Still.Repo

  @doc """
  Returns the list of all applications, ordered by name.
  """
  def list_applications do
    Repo.all(from a in Application, order_by: a.name)
  end

  @doc """
  Fetches an application by name. Raises `Ecto.NoResultsError` if not found.
  """
  def get_application_by_name!(name) when is_binary(name) do
    Repo.get_by!(Application, name: name)
  end

  @doc """
  Fetches an application by name. Returns `nil` if not found — the
  nil-returning variant used by plugs that translate the absence into a
  404 response themselves.
  """
  def get_application_by_name(name) when is_binary(name) do
    Repo.get_by(Application, name: name)
  end

  @doc """
  Creates an application. Returns `{:ok, application}` or `{:error, changeset}`.
  """
  def create_application(%Actor{} = actor, attrs) when is_map(attrs) do
    Multi.new()
    |> Multi.insert(
      :application,
      %Application{}
      |> Application.creation_changeset(attrs)
      |> validate_controller_domain_conflict()
      |> validate_domain_path_conflict()
    )
    |> Audit.multi(actor, fn %{application: app} ->
      [
        type: :application_created,
        subject_type: :application,
        subject_id: app.id,
        payload: %{
          application_id: app.id,
          application_name: app.name,
          type: app.type
        },
        after: Audit.snapshot(app)
      ]
    end)
    |> Repo.transaction()
    |> finalize(:application, fleet_changing: true)
  end

  @doc """
  Updates an application's mutable fields. `name` and `type` cannot be changed.
  """
  def update_application(%Actor{} = actor, %Application{} = application, attrs)
      when is_map(attrs) do
    before_snapshot = Audit.snapshot(application)

    Multi.new()
    |> Multi.update(
      :application,
      application
      |> Application.update_changeset(attrs)
      |> validate_controller_domain_conflict()
      |> validate_domain_path_conflict()
    )
    |> Audit.multi(actor, fn %{application: updated} ->
      [
        type: :application_updated,
        subject_type: :application,
        subject_id: updated.id,
        payload: %{application_id: updated.id, application_name: updated.name},
        before: before_snapshot,
        after: Audit.snapshot(updated)
      ]
    end)
    |> Repo.transaction()
    |> finalize(:application, fleet_changing: true)
  end

  @doc """
  Deletes an application.
  """
  def delete_application(%Actor{} = actor, %Application{} = application) do
    before_snapshot = Audit.snapshot(application)

    Multi.new()
    |> Multi.delete(:application, application)
    |> Audit.multi(actor, fn %{application: deleted} ->
      [
        type: :application_deleted,
        subject_type: :application,
        subject_id: deleted.id,
        payload: %{application_id: deleted.id, application_name: deleted.name},
        before: before_snapshot
      ]
    end)
    |> Repo.transaction()
    |> finalize(:application, fleet_changing: true)
  end

  @doc """
  Assigns a server to an application with a blue/green port pair.

  If `attrs` includes both `:port_blue` and `:port_green`, those ports are used.
  Otherwise the next available pair is picked from the configured
  `:auto_port_range` on the given server.

  Returns `{:ok, %ApplicationServer{}}` on success, `{:error, changeset}` on
  validation failure (including manual port collision — the unique index on
  `(server_id, port_blue)` catches the race between concurrent auto-assignments
  on the same server), or `{:error, :no_available_ports}` when auto-assignment
  cannot find a free pair on the given server.
  """
  def assign_server(
        %Actor{} = actor,
        %Application{} = application,
        %Server{} = server,
        attrs \\ %{}
      )
      when is_map(attrs) do
    with {:ok, attrs_with_ports} <- ensure_ports(server, normalize_port_keys(attrs)) do
      Multi.new()
      |> Multi.insert(:assignment, assignment_changeset(application, server, attrs_with_ports))
      |> Audit.multi(actor, fn %{assignment: assignment} ->
        [
          type: :application_server_assigned,
          subject_type: :application_server,
          subject_id: assignment.id,
          payload: %{
            application_id: application.id,
            application_name: application.name,
            server_id: server.id,
            server_name: server.name,
            port_blue: assignment.port_blue,
            port_green: assignment.port_green
          },
          after: Audit.snapshot(assignment)
        ]
      end)
      |> Repo.transaction()
      |> finalize(:assignment, fleet_changing: true)
    end
  end

  # Controller params arrive string-keyed with integer values; the rest of
  # the context uses atom keys. Normalize once at the boundary so the
  # internal plumbing stays tidy.
  defp normalize_port_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {"port_blue", v}, acc when is_integer(v) -> Map.put(acc, :port_blue, v)
      {"port_green", v}, acc when is_integer(v) -> Map.put(acc, :port_green, v)
      {:port_blue, v}, acc when is_integer(v) -> Map.put(acc, :port_blue, v)
      {:port_green, v}, acc when is_integer(v) -> Map.put(acc, :port_green, v)
      _, acc -> acc
    end)
  end

  @doc """
  Removes a server assignment from an application.
  """
  def unassign_server(%Actor{} = actor, %ApplicationServer{} = assignment) do
    assignment = Repo.preload(assignment, [:application, :server])
    before_snapshot = Audit.snapshot(assignment)

    Multi.new()
    |> Multi.delete(:assignment, assignment)
    |> Audit.multi(actor, fn %{assignment: deleted} ->
      [
        type: :application_server_unassigned,
        subject_type: :application_server,
        subject_id: deleted.id,
        payload: %{
          application_id: assignment.application.id,
          application_name: assignment.application.name,
          server_id: assignment.server.id,
          server_name: assignment.server.name
        },
        before: before_snapshot
      ]
    end)
    |> Repo.transaction()
    |> finalize(:assignment, fleet_changing: true)
  end

  # Unwraps the multi result, emits the audit event live (after commit),
  # and fires the fleet-changed signal for routing-affecting mutations.
  # Stays in one place so every mutation funnels through the same
  # post-commit ordering: emit live → broadcast fleet_changed → return.
  defp finalize({:ok, %{audit: event} = changes}, key, opts) do
    Audit.emit_live(event)
    if Keyword.get(opts, :fleet_changing, false), do: Events.fleet_changed()
    {:ok, Map.fetch!(changes, key)}
  end

  defp finalize({:error, _failed_op, value, _changes}, _key, _opts), do: {:error, value}

  # The controller's own host is owned end-to-end by the `still_controller`
  # Caddy route: host-scoped, terminal, matching every path, and ordered ahead
  # of per-app routes. An app deployed on that same domain would be shadowed
  # for every path and silently never receive traffic — so reject it up front.
  # Only meaningful when a controller_domain is configured; left blank, Caddy
  # host-scopes to the node's own address, which a real app domain won't hit.
  defp validate_controller_domain_conflict(%Changeset{} = changeset) do
    domain = Changeset.get_field(changeset, :domain)
    controller_domain = Elixir.Application.get_env(:still, :controller_domain)

    if controller_domain_conflict?(domain, controller_domain) do
      Changeset.add_error(
        changeset,
        :domain,
        "is the controller's own domain — Still serves the dashboard and API there"
      )
    else
      changeset
    end
  end

  defp controller_domain_conflict?(domain, controller_domain)
       when is_binary(domain) and is_binary(controller_domain) and controller_domain != "" do
    String.downcase(domain) == String.downcase(controller_domain)
  end

  defp controller_domain_conflict?(_domain, _controller_domain), do: false

  # Two apps on the same domain with the same path prefix produce two terminal
  # Caddy routes; the first wins and the second silently never receives traffic.
  # Reject the collision at create/update time (excluding self on update).
  # Distinct path prefixes on a shared domain are fine — that's path-based
  # multiplexing. (Admin-only, infrequent operation, so the check-then-insert
  # race is acceptable for v0.1.)
  defp validate_domain_path_conflict(%Changeset{} = changeset) do
    domain = Changeset.get_field(changeset, :domain)
    path_prefix = Changeset.get_field(changeset, :path_prefix)

    if is_binary(domain) and domain_path_taken?(domain, path_prefix, changeset.data.id) do
      Changeset.add_error(
        changeset,
        :domain,
        "is already used by another application with the same path prefix"
      )
    else
      changeset
    end
  end

  defp domain_path_taken?(domain, path_prefix, self_id) do
    from(a in Application, where: a.domain == ^domain)
    |> exclude_application(self_id)
    |> match_path_prefix(path_prefix)
    |> Repo.exists?()
  end

  defp exclude_application(query, nil), do: query
  defp exclude_application(query, id), do: from(a in query, where: a.id != ^id)

  defp match_path_prefix(query, nil), do: from(a in query, where: is_nil(a.path_prefix))
  defp match_path_prefix(query, prefix), do: from(a in query, where: a.path_prefix == ^prefix)

  @doc """
  Lists all server assignments for the given application (or scope),
  ordered by insertion time.
  """
  def list_application_servers(%Application{} = application) do
    Repo.all(
      from as in ApplicationServer,
        where: as.application_id == ^application.id,
        order_by: as.inserted_at
    )
  end

  def list_application_servers(%Scope{application: %Application{} = application}) do
    list_application_servers(application)
  end

  @doc """
  Fetches an application server assignment by id. Raises if not found.
  """
  def get_application_server!(id) when is_binary(id) do
    Repo.get!(ApplicationServer, id)
  end

  @doc """
  Fetches an application server assignment scoped to the scope's
  application. A child id that belongs to a different application raises
  `Ecto.NoResultsError`, which the fallback controller renders as 404.
  """
  def get_application_server!(%Scope{application: %Application{id: app_id}}, id)
      when is_binary(id) do
    Repo.one!(
      from as in ApplicationServer,
        where: as.id == ^id and as.application_id == ^app_id
    )
  end

  defp assignment_changeset(application, server, attrs) do
    ApplicationServer.assignment_changeset(
      %ApplicationServer{},
      Map.merge(attrs, %{application_id: application.id, server_id: server.id})
    )
  end

  defp ensure_ports(%Server{} = server, attrs) do
    if Map.has_key?(attrs, :port_blue) and Map.has_key?(attrs, :port_green) do
      validate_manual_ports(server.id, attrs)
    else
      case next_available_port_pair(server.id) do
        {:ok, {port_blue, port_green}} ->
          {:ok, Map.merge(attrs, %{port_blue: port_blue, port_green: port_green})}

        {:error, _} = error ->
          error
      end
    end
  end

  # Manually-chosen ports must not collide with EITHER column of an existing
  # assignment on this server. The per-column unique indexes catch blue-vs-blue
  # and green-vs-green, but not one assignment's blue equal to another's green —
  # which would hand two processes the same TCP port and fail the second deploy
  # with EADDRINUSE at runtime instead of a clear error here.
  defp validate_manual_ports(server_id, attrs) do
    used = used_ports(server_id)
    proposed = Enum.reject([attrs[:port_blue], attrs[:port_green]], &is_nil/1)

    if Enum.any?(proposed, &MapSet.member?(used, &1)) do
      {:error, :port_in_use}
    else
      {:ok, attrs}
    end
  end

  defp used_ports(server_id) do
    from(as in ApplicationServer,
      where: as.server_id == ^server_id,
      select: {as.port_blue, as.port_green}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {b, g} -> [b, g] end)
    |> MapSet.new()
  end

  defp next_available_port_pair(server_id) do
    used = used_ports(server_id)

    # `Application` here is our schema alias; reach for the stdlib via the
    # `Elixir.` prefix to escape the alias.
    range = Elixir.Application.fetch_env!(:still, :auto_port_range)

    case Enum.find(range, fn port_blue ->
           port_blue not in used and (port_blue + 1) not in used
         end) do
      nil -> {:error, :no_available_ports}
      port_blue -> {:ok, {port_blue, port_blue + 1}}
    end
  end

  @doc """
  Creates a hook for the given application. Returns `{:ok, hook}` or `{:error, changeset}`.
  """
  def create_hook(%Actor{} = actor, %Application{} = application, attrs) when is_map(attrs) do
    changeset =
      %Hook{}
      |> Hook.creation_changeset(attrs)
      |> Ecto.Changeset.put_change(:application_id, application.id)

    Multi.new()
    |> Multi.insert(:hook, changeset)
    |> Audit.multi(actor, fn %{hook: hook} ->
      [
        type: :hook_created,
        subject_type: :hook,
        subject_id: hook.id,
        payload: %{
          hook_id: hook.id,
          application_id: application.id,
          application_name: application.name,
          event: hook.event
        },
        after: Audit.snapshot(hook)
      ]
    end)
    |> Repo.transaction()
    |> finalize(:hook, fleet_changing: false)
  end

  @doc """
  Lists all hooks for the given application (or scope), ordered by event
  name.
  """
  def list_hooks_for(%Application{} = application) do
    Repo.all(
      from h in Hook,
        where: h.application_id == ^application.id,
        order_by: h.event
    )
  end

  def list_hooks_for(%Scope{application: %Application{} = application}) do
    list_hooks_for(application)
  end

  @doc """
  Fetches a hook by id. Raises `Ecto.NoResultsError` if not found.
  """
  def get_hook!(id) when is_binary(id) do
    Repo.get!(Hook, id)
  end

  @doc """
  Fetches a hook by id scoped to the scope's application. Cross-application
  access raises `Ecto.NoResultsError`.
  """
  def get_hook!(%Scope{application: %Application{id: app_id}}, id) when is_binary(id) do
    Repo.one!(from h in Hook, where: h.id == ^id and h.application_id == ^app_id)
  end

  @doc """
  Updates a hook's script and timeout. The event and parent application
  cannot be changed after creation.
  """
  def update_hook(%Actor{} = actor, %Hook{} = hook, attrs) when is_map(attrs) do
    before_snapshot = Audit.snapshot(hook)

    Multi.new()
    |> Multi.update(:hook, Hook.update_changeset(hook, attrs))
    |> Audit.multi(actor, fn %{hook: updated} ->
      [
        type: :hook_updated,
        subject_type: :hook,
        subject_id: updated.id,
        payload: %{hook_id: updated.id, event: updated.event},
        before: before_snapshot,
        after: Audit.snapshot(updated)
      ]
    end)
    |> Repo.transaction()
    |> finalize(:hook, fleet_changing: false)
  end

  @doc """
  Deletes a hook.
  """
  def delete_hook(%Actor{} = actor, %Hook{} = hook) do
    before_snapshot = Audit.snapshot(hook)

    Multi.new()
    |> Multi.delete(:hook, hook)
    |> Audit.multi(actor, fn %{hook: deleted} ->
      [
        type: :hook_deleted,
        subject_type: :hook,
        subject_id: deleted.id,
        payload: %{hook_id: deleted.id, event: deleted.event},
        before: before_snapshot
      ]
    end)
    |> Repo.transaction()
    |> finalize(:hook, fleet_changing: false)
  end

  @doc """
  Returns all application server assignments as a flat list of maps with
  `:application_name`, `:server_id`, and `:desired_version`. Used by the
  reconciliation loop to compare desired state against agent reports.
  """
  def list_all_assignments do
    Repo.all(
      from as in ApplicationServer,
        join: a in assoc(as, :application),
        select: %{
          application_name: a.name,
          server_id: as.server_id,
          desired_version: as.desired_version
        }
    )
  end

  @doc """
  Returns the routing registry — one entry per application that has at
  least one server assignment, each carrying the list of servers the
  application runs on. Applications without any assignments are omitted.

  Shape: `[%{application: %Application{}, servers: [%Server{}]}]`, sorted
  alphabetically by application name and then by server name. Rendering
  the transport shape (ports, JSON keys, convention choices) is left to
  the caller — this context function just joins the rows.
  """
  def list_routes do
    rows =
      Repo.all(
        from a in Application,
          join: as in ApplicationServer,
          on: as.application_id == a.id,
          join: s in Server,
          on: s.id == as.server_id,
          order_by: [asc: a.name, asc: s.name],
          select: {a, s}
      )

    rows
    |> Enum.group_by(fn {a, _s} -> a end, fn {_a, s} -> s end)
    |> Enum.sort_by(fn {a, _} -> a.name end)
    |> Enum.map(fn {a, servers} -> %{application: a, servers: servers} end)
  end

  @doc """
  Returns `true` if the given server has any application assignments.
  """
  def server_has_assignments?(server_id) when is_binary(server_id) do
    Repo.exists?(from as in ApplicationServer, where: as.server_id == ^server_id)
  end

  @doc """
  Returns `true` if the given application has any server assignments.
  """
  def application_has_assignments?(application_id) when is_binary(application_id) do
    Repo.exists?(from as in ApplicationServer, where: as.application_id == ^application_id)
  end

  @doc """
  Sets the desired version on an application server assignment.
  """
  def set_desired_version(%ApplicationServer{} = assignment, version)
      when is_binary(version) do
    assignment
    |> Ecto.Changeset.change(%{desired_version: version})
    |> Repo.update()
  end

  @doc """
  Stamps every server assignment for the given application with the same
  desired version. Called by the orchestrator when a deploy or rollback
  starts so the DB reflects the fleet-wide target while the rolling
  sequence converges the actual state.

  Returns the number of rows updated.
  """
  def set_desired_version_for_all(%Application{} = application, version)
      when is_binary(version) do
    {count, _} =
      Repo.update_all(
        from(as in ApplicationServer, where: as.application_id == ^application.id),
        set: [desired_version: version, updated_at: DateTime.utc_now()]
      )

    count
  end
end
