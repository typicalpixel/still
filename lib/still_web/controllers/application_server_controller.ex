defmodule StillWeb.ApplicationServerController do
  @moduledoc """
  Assign/list/unassign servers for an application.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :read when action in [:index]
  plug StillWeb.Plugs.Authorize, :admin when action in [:create, :delete]

  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Fleet
  alias StillWeb.ApplicationServerJSON
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope

  tags(["ApplicationServers"])

  @app_param [
    application_name: [in: :path, schema: %OpenApiSpex.Schema{type: :string}, required: true]
  ]

  operation(:index,
    summary: "List servers assigned to an application",
    parameters: @app_param,
    responses: [
      ok: {"Assignments", "application/json", Envelope.list(Schemas.ApplicationServer)}
    ]
  )

  def index(%Plug.Conn{} = conn, _params) do
    assignments = Applications.list_application_servers(conn.assigns.current_scope)
    json(conn, ApplicationServerJSON.render(assignments))
  end

  operation(:create,
    summary: "Assign a server to an application",
    parameters: @app_param,
    request_body: {"Assignment", "application/json", Schemas.AssignServerRequest},
    responses: [
      created: {"Assignment", "application/json", Envelope.single(Schemas.ApplicationServer)},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      conflict: {"No available port pair", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  def create(%Plug.Conn{} = conn, params) when is_map(params) do
    scope = conn.assigns.current_scope
    server = Fleet.get_server!(params["server_id"])
    actor = Actor.from_conn(conn)

    with {:ok, assignment} <- Applications.assign_server(actor, scope.application, server, params) do
      conn |> put_status(:created) |> json(ApplicationServerJSON.render_one(assignment))
    end
  end

  operation(:delete,
    summary: "Unassign a server from an application",
    parameters:
      @app_param ++
        [
          id: [
            in: :path,
            schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
            required: true
          ]
        ],
    responses: [
      no_content: "Unassigned",
      not_found: {"Unknown assignment id", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  def delete(%Plug.Conn{} = conn, %{"id" => id}) do
    assignment = Applications.get_application_server!(conn.assigns.current_scope, id)
    {:ok, _} = Applications.unassign_server(Actor.from_conn(conn), assignment)
    send_resp(conn, :no_content, "")
  end
end
