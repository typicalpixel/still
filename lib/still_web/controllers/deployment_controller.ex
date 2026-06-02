defmodule StillWeb.DeploymentController do
  @moduledoc """
  Trigger, list, and inspect deployments.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :read when action in [:index, :show]
  plug StillWeb.Plugs.Authorize, :deploy when action in [:create]
  plug StillWeb.Plugs.Authorize, :rollback when action in [:rollback]

  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Orchestrator
  alias StillWeb.DeploymentJSON
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope

  tags(["Deployments"])

  operation(:create,
    summary: "Trigger a deployment",
    parameters: [
      application_name: [in: :path, schema: %OpenApiSpex.Schema{type: :string}, required: true]
    ],
    request_body: {"Deployment attributes", "application/json", Schemas.CreateDeploymentRequest},
    responses: [
      created: {"Deployment", "application/json", Envelope.single(Schemas.Deployment)},
      conflict:
        {"Deployment in progress, no servers assigned, or insufficient healthy agents",
         "application/json", Schemas.Error},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Deploy permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Triggers a deployment via the Orchestrator."
  def create(%Plug.Conn{} = conn, params) when is_map(params) do
    scope = conn.assigns.current_scope

    attrs = %{
      version: params["version"],
      artifact_url: params["artifact_url"],
      source: params["source"],
      initiated_by: "user:#{conn.assigns.current_user.email}"
    }

    with {:ok, deployment} <-
           Orchestrator.trigger_deployment(Actor.from_conn(conn), scope.application, attrs) do
      conn |> put_status(:created) |> json(DeploymentJSON.render_created(deployment))
    end
  end

  operation(:index,
    summary: "List deployments, newest first",
    parameters: [
      application: [in: :query, schema: %OpenApiSpex.Schema{type: :string}],
      server: [in: :query, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}],
      status: [
        in: :query,
        schema: %OpenApiSpex.Schema{
          type: :string,
          enum: ["pending", "in_progress", "completed", "failed", "rolled_back"]
        }
      ],
      initiated_by: [in: :query, schema: %OpenApiSpex.Schema{type: :string}],
      limit: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 500, default: 50}
      ],
      before: [in: :query, schema: %OpenApiSpex.Schema{type: :string, format: :"date-time"}]
    ],
    responses: [
      ok:
        {"Deployments (each with `application_name` inlined)", "application/json",
         Envelope.list(Schemas.Deployment)}
    ]
  )

  @doc """
  Lists deployments, newest first. Filterable by `application`, `server`,
  `status`, `initiated_by`; paginated via `limit` and `before` (ISO-8601).
  """
  def index(%Plug.Conn{} = conn, params) when is_map(params) do
    deployments = Deployments.list_deployments(params)
    json(conn, DeploymentJSON.render(deployments))
  end

  operation(:show,
    summary: "Show a deployment with per-server steps",
    parameters: [
      id: [in: :path, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}, required: true]
    ],
    responses: [
      ok: {"Deployment with steps", "application/json", Envelope.single(Schemas.Deployment)},
      not_found: {"Unknown id", "application/json", Schemas.Error}
    ]
  )

  @doc "Shows a single deployment with per-server steps."
  def show(%Plug.Conn{} = conn, %{"id" => id}) do
    deployment = Deployments.get_deployment!(id)
    json(conn, DeploymentJSON.render_one(deployment))
  end

  operation(:rollback,
    summary: "Roll back to the previous successful version",
    parameters: [
      application_name: [in: :path, schema: %OpenApiSpex.Schema{type: :string}, required: true]
    ],
    responses: [
      accepted:
        {"Rollback deployment created", "application/json", Envelope.single(Schemas.Deployment)},
      conflict:
        {"Deployment in progress, no rollback target, or insufficient healthy agents",
         "application/json", Schemas.Error},
      forbidden: {"Rollback permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Triggers a rollback to the previous successful version."
  def rollback(%Plug.Conn{} = conn, _params) do
    scope = conn.assigns.current_scope
    attrs = %{initiated_by: "user:#{conn.assigns.current_user.email}"}

    with {:ok, deployment} <-
           Orchestrator.trigger_rollback(Actor.from_conn(conn), scope.application, attrs) do
      conn |> put_status(:accepted) |> json(DeploymentJSON.render_created(deployment))
    end
  end
end
