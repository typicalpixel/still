defmodule StillWeb.ApplicationController do
  @moduledoc """
  CRUD for applications.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :read when action in [:index, :show]
  plug StillWeb.Plugs.Authorize, :admin when action in [:create, :update, :delete]

  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Orchestrator
  alias StillWeb.ApplicationJSON
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope

  tags(["Applications"])

  operation(:index,
    summary: "List all applications",
    responses: [
      ok: {"Applications", "application/json", Envelope.list(Schemas.Application)}
    ]
  )

  def index(%Plug.Conn{} = conn, _params) do
    applications = Applications.list_applications()
    json(conn, ApplicationJSON.render(applications))
  end

  operation(:create,
    summary: "Create an application",
    description: "`name` and `type` are immutable after creation.",
    request_body:
      {"Application attributes", "application/json", Schemas.CreateApplicationRequest},
    responses: [
      created: {"Application", "application/json", Envelope.single(Schemas.Application)},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  def create(%Plug.Conn{} = conn, params) when is_map(params) do
    with {:ok, application} <- Applications.create_application(Actor.from_conn(conn), params) do
      conn |> put_status(:created) |> json(ApplicationJSON.render_one(application))
    end
  end

  operation(:show,
    summary: "Show an application by name",
    parameters: [name: [in: :path, schema: %OpenApiSpex.Schema{type: :string}, required: true]],
    responses: [
      ok: {"Application", "application/json", Envelope.single(Schemas.Application)},
      not_found: {"Unknown name", "application/json", Schemas.Error}
    ]
  )

  def show(%Plug.Conn{} = conn, %{"name" => name}) do
    application = Applications.get_application_by_name!(name)
    json(conn, ApplicationJSON.render_one(application))
  end

  operation(:update,
    summary: "Update an application's mutable fields",
    description: "`name` and `type` cannot be changed.",
    parameters: [name: [in: :path, schema: %OpenApiSpex.Schema{type: :string}, required: true]],
    request_body: {"Patch", "application/json", Schemas.UpdateApplicationRequest},
    responses: [
      ok: {"Application", "application/json", Envelope.single(Schemas.Application)},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  def update(%Plug.Conn{} = conn, %{"name" => name} = params) do
    application = Applications.get_application_by_name!(name)

    with {:ok, updated} <-
           Orchestrator.update_application(Actor.from_conn(conn), application, params) do
      json(conn, ApplicationJSON.render_one(updated))
    end
  end

  operation(:delete,
    summary: "Delete an application",
    description: "Rejects (409) if any servers are still assigned.",
    parameters: [name: [in: :path, schema: %OpenApiSpex.Schema{type: :string}, required: true]],
    responses: [
      no_content: "Deleted",
      conflict: {"Application has servers assigned", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  def delete(%Plug.Conn{} = conn, %{"name" => name}) do
    application = Applications.get_application_by_name!(name)

    if Applications.application_has_assignments?(application.id) do
      {:error, :application_has_assignments}
    else
      {:ok, _} = Applications.delete_application(Actor.from_conn(conn), application)
      send_resp(conn, :no_content, "")
    end
  end
end
