defmodule StillWeb.Schemas.WebhookDeployRequest do
  @moduledoc "Body for `POST /api/webhooks/deploy`. Same as a regular deploy, with the application name in the body."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "WebhookDeployRequest",
    type: :object,
    properties: %{
      application: %OpenApiSpex.Schema{type: :string},
      version: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 255},
      artifact_url: %OpenApiSpex.Schema{
        type: :string,
        format: :uri,
        minLength: 1,
        maxLength: 2048
      },
      source: %OpenApiSpex.Schema{type: :string, maxLength: 255}
    },
    required: [:application, :version, :artifact_url]
  })
end
