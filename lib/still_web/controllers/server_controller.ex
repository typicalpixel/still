defmodule StillWeb.ServerController do
  @moduledoc """
  CRUD for servers in the fleet.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :read when action in [:index, :show]
  plug StillWeb.Plugs.Authorize, :admin when action in [:create, :update, :delete]

  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Fleet
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope
  alias StillWeb.ServerJSON

  tags(["Servers"])

  operation(:index,
    summary: "List all servers",
    responses: [
      ok: {"Servers", "application/json", Envelope.list(Schemas.Server)},
      unauthorized: {"Missing or invalid token", "application/json", Schemas.Error}
    ]
  )

  @doc "Lists all servers."
  def index(%Plug.Conn{} = conn, _params) do
    servers = Fleet.list_servers()

    connected_ids =
      for s <- servers, AgentConnectionManager.connected?(s.id), into: MapSet.new(), do: s.id

    json(conn, ServerJSON.render(servers, connected_ids))
  end

  operation(:create,
    summary: "Register a new server",
    request_body: {"Server attributes", "application/json", Schemas.CreateServerRequest},
    responses: [
      created: {"Server", "application/json", Envelope.single(Schemas.Server)},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Registers a new server."
  def create(%Plug.Conn{} = conn, params) when is_map(params) do
    with {:ok, server} <- Fleet.create_server(Actor.from_conn(conn), params) do
      conn
      |> put_status(:created)
      |> json(ServerJSON.render_one(server, AgentConnectionManager.connected?(server.id)))
    end
  end

  operation(:show,
    summary: "Show a server by id",
    parameters: [
      id: [in: :path, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [
      ok: {"Server", "application/json", Envelope.single(Schemas.Server)},
      not_found: {"Unknown id", "application/json", Schemas.Error}
    ]
  )

  @doc "Shows a single server by id."
  def show(%Plug.Conn{} = conn, %{"id" => id}) do
    server = Fleet.get_server!(id)
    json(conn, ServerJSON.render_one(server, AgentConnectionManager.connected?(server.id)))
  end

  operation(:update,
    summary: "Update a server's user-editable fields",
    parameters: [
      id: [in: :path, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}, required: true]
    ],
    request_body: {"Patch", "application/json", Schemas.UpdateServerRequest},
    responses: [
      ok: {"Server", "application/json", Envelope.single(Schemas.Server)},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Updates a server's user-editable fields."
  def update(%Plug.Conn{} = conn, %{"id" => id} = params) do
    server = Fleet.get_server!(id)

    with {:ok, updated} <- Fleet.update_server(Actor.from_conn(conn), server, params) do
      json(conn, ServerJSON.render_one(updated, AgentConnectionManager.connected?(updated.id)))
    end
  end

  operation(:delete,
    summary: "Delete a server",
    description: "Rejects (409) if any application is still assigned to this server.",
    parameters: [
      id: [in: :path, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [
      no_content: "Deleted",
      conflict: {"Server has applications assigned", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Deletes a server. Rejects if applications are assigned."
  def delete(%Plug.Conn{} = conn, %{"id" => id}) do
    server = Fleet.get_server!(id)

    if Applications.server_has_assignments?(server.id) do
      {:error, :server_has_assignments}
    else
      {:ok, _} = Fleet.delete_server(Actor.from_conn(conn), server)
      send_resp(conn, :no_content, "")
    end
  end
end
