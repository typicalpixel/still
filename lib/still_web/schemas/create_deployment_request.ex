defmodule StillWeb.Schemas.CreateDeploymentRequest do
  @moduledoc "Body for `POST /api/applications/:application_name/deployments`."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateDeploymentRequest",
    type: :object,
    properties: %{
      version: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 255},
      artifact_url: %OpenApiSpex.Schema{
        type: :string,
        format: :uri,
        minLength: 1,
        maxLength: 2048
      },
      source: %OpenApiSpex.Schema{
        type: :string,
        maxLength: 255,
        description: "Optional provenance tag — e.g. `git:main@abc1234`, `ci:nightly-prod`."
      },
      initiated_by: %OpenApiSpex.Schema{
        type: :string,
        maxLength: 255,
        description:
          "Optional human this deploy is attributed to, for shared CI keys (e.g. the commit author). " <>
            "Caller-asserted — the API key remains the authenticated actor. Defaults to the key owner."
      }
    },
    required: [:version, :artifact_url]
  })
end
