defmodule StillWeb.WebhookController do
  @moduledoc """
  CI/CD convenience endpoint. Same as triggering a deployment via the
  applications API, but the application name is in the request body
  instead of the URL.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :deploy when action in [:deploy]

  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Orchestrator
  alias StillWeb.Schemas

  tags(["Webhooks"])

  operation(:deploy,
    summary: "Trigger a deployment from a CI/CD payload",
    description:
      "Same semantics as `POST /api/applications/:name/deployments`, but the application name is in the body.",
    request_body: {"Webhook payload", "application/json", Schemas.WebhookDeployRequest},
    responses: [
      created: {"Deployment id", "application/json", Schemas.WebhookDeployResponse},
      not_found: {"Unknown application", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      bad_request: {"Missing application", "application/json", Schemas.Error},
      forbidden: {"Deploy permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Triggers a deployment from a webhook payload."
  def deploy(%Plug.Conn{} = conn, %{"application" => name} = params)
      when is_binary(name) do
    application = Applications.get_application_by_name!(name)

    attrs = %{
      version: params["version"],
      artifact_url: params["artifact_url"],
      source: params["source"],
      initiated_by: "api:#{conn.assigns.current_user.email}"
    }

    case Orchestrator.trigger_deployment(Actor.from_conn(conn), application, attrs) do
      {:ok, deployment} ->
        conn |> put_status(:created) |> json(%{data: %{deployment_id: deployment.id}})

      {:error, _} = error ->
        error
    end
  end

  def deploy(%Plug.Conn{} = _conn, _params) do
    {:error, :bad_request}
  end
end
