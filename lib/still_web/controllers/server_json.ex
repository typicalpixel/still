defmodule StillWeb.ServerJSON do
  @moduledoc """
  JSON serialization for server CRUD endpoints.

  `status` is computed live: the caller (`ServerController`) passes a
  set of connected server ids (or a single boolean for show/create/update),
  resolved from `Still.AgentConnectionManager`. Persisted server rows
  carry no connection state — the controller's ETS table is the source
  of truth for live connectivity.

  The `metadata` map is agent-reported (see `Still.Agent.SystemInfo`) and
  passes through verbatim — keys come out of SQLite as strings, which is
  exactly what wire clients expect.
  """

  alias Still.Fleet.Server

  @doc """
  Renders a list of servers. `connected_ids` is a MapSet of server ids
  currently tracked as connected by the controller.
  """
  def render(servers, connected_ids \\ MapSet.new())
      when is_list(servers) do
    %{data: Enum.map(servers, &server(&1, MapSet.member?(connected_ids, &1.id)))}
  end

  @doc "Renders a single server."
  def render_one(%Server{} = server, connected? \\ false) when is_boolean(connected?) do
    %{data: server(server, connected?)}
  end

  @doc "Base shape for a server row with live connection status."
  def server(%Server{} = server, connected? \\ false) when is_boolean(connected?) do
    %{
      id: server.id,
      name: server.name,
      host: server.host,
      roles: server.roles,
      status: if(connected?, do: :connected, else: :disconnected),
      last_seen_at: server.last_seen_at,
      metadata: server.metadata,
      inserted_at: server.inserted_at,
      updated_at: server.updated_at
    }
  end
end
