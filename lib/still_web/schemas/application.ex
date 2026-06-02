defmodule StillWeb.Schemas.Application do
  @moduledoc "An application registered for deployment to one or more servers."

  require OpenApiSpex

  alias StillWeb.Schemas.{ArtifactSource, HealthCheck}

  OpenApiSpex.schema(%{
    title: "Application",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      name: %OpenApiSpex.Schema{type: :string},
      type: %OpenApiSpex.Schema{
        type: :string,
        enum: ["elixir_release", "static_site", "process"]
      },
      domain: %OpenApiSpex.Schema{type: :string},
      path_prefix: %OpenApiSpex.Schema{type: :string, nullable: true},
      exec_command: %OpenApiSpex.Schema{type: :string, nullable: true},
      env_vars: %OpenApiSpex.Schema{
        type: :object,
        additionalProperties: %OpenApiSpex.Schema{type: :string}
      },
      min_healthy: %OpenApiSpex.Schema{type: :integer, minimum: 1},
      health_check: %OpenApiSpex.Schema{nullable: true, allOf: [HealthCheck]},
      artifact_source: ArtifactSource,
      maintenance: %OpenApiSpex.Schema{type: :boolean},
      maintenance_message: %OpenApiSpex.Schema{type: :string, nullable: true},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :name, :type, :domain, :min_healthy, :artifact_source]
  })
end
