defmodule StillWeb.Schemas.WebhookDeployResponse do
  @moduledoc "201 response for `POST /api/webhooks/deploy`. Returns just the new deployment's id."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "WebhookDeployResponse",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{deployment_id: %OpenApiSpex.Schema{type: :string, format: :uuid}},
        required: [:deployment_id]
      }
    },
    required: [:data]
  })
end
