defmodule StillWeb.Schemas.UpdateApplicationRequest do
  @moduledoc "Body for `PATCH /api/applications/:name`. `name` and `type` cannot be changed."

  require OpenApiSpex

  alias StillWeb.Schemas.{ArtifactSource, HealthCheck}

  OpenApiSpex.schema(%{
    title: "UpdateApplicationRequest",
    type: :object,
    properties: %{
      domain: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 255},
      path_prefix: %OpenApiSpex.Schema{type: :string, maxLength: 255},
      exec_command: %OpenApiSpex.Schema{type: :string, maxLength: 1000},
      exec_start_pre: %OpenApiSpex.Schema{type: :string, maxLength: 1000},
      exec_stop: %OpenApiSpex.Schema{type: :string, maxLength: 1000},
      env_vars: %OpenApiSpex.Schema{
        type: :object,
        additionalProperties: %OpenApiSpex.Schema{type: :string}
      },
      min_healthy: %OpenApiSpex.Schema{type: :integer, minimum: 1},
      health_check: %OpenApiSpex.Schema{nullable: true, allOf: [HealthCheck]},
      artifact_source: ArtifactSource,
      maintenance: %OpenApiSpex.Schema{type: :boolean},
      maintenance_message: %OpenApiSpex.Schema{type: :string, maxLength: 500, nullable: true}
    }
  })
end
