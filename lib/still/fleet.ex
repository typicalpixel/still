defmodule Still.Fleet do
  @moduledoc """
  The Fleet context — server registration, lookup, and lifecycle.
  """

  alias Ecto.Multi
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Events
  alias Still.Fleet.Server
  alias Still.Repo

  @doc """
  Returns the list of all servers, ordered by name.
  """
  def list_servers do
    import Ecto.Query, only: [from: 2]
    Repo.all(from s in Server, order_by: s.name)
  end

  @doc """
  Fetches a server by id. Raises `Ecto.NoResultsError` if no server is found.
  """
  def get_server!(id) when is_binary(id) do
    Repo.get!(Server, id)
  end

  @doc """
  Creates a server. Returns `{:ok, server}` or `{:error, changeset}`.
  """
  def create_server(%Actor{} = actor, attrs) when is_map(attrs) do
    Multi.new()
    |> Multi.insert(:server, Server.creation_changeset(%Server{}, attrs))
    |> Audit.multi(actor, fn %{server: server} ->
      [
        type: :server_created,
        subject_type: :server,
        subject_id: server.id,
        payload: %{server_id: server.id, server_name: server.name},
        after: Audit.snapshot(server)
      ]
    end)
    |> Repo.transaction()
    |> finalize(:server)
  end

  @doc """
  Updates a server's user-editable fields. Returns `{:ok, server}` or `{:error, changeset}`.
  """
  def update_server(%Actor{} = actor, %Server{} = server, attrs) when is_map(attrs) do
    before_snapshot = Audit.snapshot(server)

    Multi.new()
    |> Multi.update(:server, Server.update_changeset(server, attrs))
    |> Audit.multi(actor, fn %{server: updated} ->
      [
        type: :server_updated,
        subject_type: :server,
        subject_id: updated.id,
        payload: %{server_id: updated.id, server_name: updated.name},
        before: before_snapshot,
        after: Audit.snapshot(updated)
      ]
    end)
    |> Repo.transaction()
    |> finalize(:server)
  end

  @doc """
  Deletes a server.
  """
  def delete_server(%Actor{} = actor, %Server{} = server) do
    before_snapshot = Audit.snapshot(server)

    Multi.new()
    |> Multi.delete(:server, server)
    |> Audit.multi(actor, fn %{server: deleted} ->
      [
        type: :server_deleted,
        subject_type: :server,
        subject_id: deleted.id,
        payload: %{server_id: deleted.id, server_name: deleted.name},
        before: before_snapshot
      ]
    end)
    |> Repo.transaction()
    |> finalize(:server)
  end

  @doc """
  Fetches a server by id, returning `nil` if not found.
  """
  def get_server(id) when is_binary(id) do
    Repo.get(Server, id)
  end

  @doc """
  Persists agent-reported facts to `servers.metadata` and stamps
  `last_seen_at`. No-op when the server id doesn't match a record —
  stray reports from a previously-deleted server shouldn't error out
  the announce path.

  Bypasses the user-facing changesets on purpose: metadata is agent-owned
  and is not exposed to the admin CRUD surface.
  """
  def record_agent_announcement(server_id, metadata, connected_at)
      when is_binary(server_id) and is_map(metadata) do
    case get_server(server_id) do
      nil ->
        :ok

      %Server{} = server ->
        server
        |> Ecto.Changeset.change(%{metadata: metadata, last_seen_at: connected_at})
        |> Repo.update!()

        :ok
    end
  end

  @doc """
  Idempotently registers a server with an explicit id. If a server already
  exists at that id the existing row is returned unchanged — mutable fields
  (name, host, roles) are left alone so operator edits via the API survive
  re-runs of the installer.
  """
  def ensure_server(%Actor{} = actor, %{id: id} = attrs) when is_binary(id) do
    case get_server(id) do
      nil ->
        changeset =
          %Server{}
          |> Server.creation_changeset(Map.delete(attrs, :id))
          |> Ecto.Changeset.put_change(:id, id)

        Multi.new()
        |> Multi.insert(:server, changeset)
        |> Audit.multi(actor, fn %{server: server} ->
          [
            type: :server_created,
            subject_type: :server,
            subject_id: server.id,
            payload: %{server_id: server.id, server_name: server.name},
            after: Audit.snapshot(server)
          ]
        end)
        |> Repo.transaction()
        |> finalize(:server)

      %Server{} = existing ->
        {:ok, existing}
    end
  end

  # Unwraps the multi result, emits the audit event live (after commit),
  # and signals the IngressReconciler. Keeps the post-commit ordering
  # consistent across every mutation in this context.
  defp finalize({:ok, %{audit: event} = changes}, key) do
    Audit.emit_live(event)
    Events.fleet_changed()
    {:ok, Map.fetch!(changes, key)}
  end

  defp finalize({:error, _failed_op, value, _changes}, _key), do: {:error, value}
end
