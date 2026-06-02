defmodule StillWeb.HookController do
  @moduledoc """
  CRUD for lifecycle hooks on an application.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :read when action in [:index]
  plug StillWeb.Plugs.Authorize, :admin when action in [:create, :update, :delete]

  alias Still.Applications
  alias Still.Audit.Actor
  alias StillWeb.HookJSON
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope

  tags(["Hooks"])

  @app_param [
    application_name: [in: :path, schema: %OpenApiSpex.Schema{type: :string}, required: true]
  ]

  @id_param [
    id: [in: :path, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}, required: true]
  ]

  operation(:index,
    summary: "List lifecycle hooks for an application",
    parameters: @app_param,
    responses: [ok: {"Hooks", "application/json", Envelope.list(Schemas.Hook)}]
  )

  def index(%Plug.Conn{} = conn, _params) do
    hooks = Applications.list_hooks_for(conn.assigns.current_scope)
    json(conn, HookJSON.render(hooks))
  end

  operation(:create,
    summary: "Create a hook",
    description: "One hook per event per application.",
    parameters: @app_param,
    request_body: {"Hook", "application/json", Schemas.CreateHookRequest},
    responses: [
      created: {"Hook", "application/json", Envelope.single(Schemas.Hook)},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  def create(%Plug.Conn{} = conn, params) when is_map(params) do
    scope = conn.assigns.current_scope

    with {:ok, hook} <-
           Applications.create_hook(Actor.from_conn(conn), scope.application, params) do
      conn |> put_status(:created) |> json(HookJSON.render_one(hook))
    end
  end

  operation(:update,
    summary: "Update a hook's script and timeout",
    description: "The event is immutable.",
    parameters: @app_param ++ @id_param,
    request_body: {"Patch", "application/json", Schemas.UpdateHookRequest},
    responses: [
      ok: {"Hook", "application/json", Envelope.single(Schemas.Hook)},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  def update(%Plug.Conn{} = conn, %{"id" => id} = params) do
    hook = Applications.get_hook!(conn.assigns.current_scope, id)

    with {:ok, updated} <- Applications.update_hook(Actor.from_conn(conn), hook, params) do
      json(conn, HookJSON.render_one(updated))
    end
  end

  operation(:delete,
    summary: "Delete a hook",
    parameters: @app_param ++ @id_param,
    responses: [
      no_content: "Deleted",
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  def delete(%Plug.Conn{} = conn, %{"id" => id}) do
    hook = Applications.get_hook!(conn.assigns.current_scope, id)
    {:ok, _} = Applications.delete_hook(Actor.from_conn(conn), hook)
    send_resp(conn, :no_content, "")
  end
end
