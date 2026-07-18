defmodule StillWeb.Schemas.CreateApplicationRequest do
  @moduledoc "Body for `POST /api/applications`. `name` and `type` are immutable after creation."

  require OpenApiSpex

  alias StillWeb.Schemas.{ArtifactSource, HealthCheck}

  OpenApiSpex.schema(%{
    title: "CreateApplicationRequest",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{
        type: :string,
        pattern: ~S"^[a-z][a-z0-9_-]*$",
        minLength: 1,
        maxLength: 100,
        description:
          "Lowercase letter followed by lowercase letters, digits, hyphens, or underscores."
      },
      type: %OpenApiSpex.Schema{
        type: :string,
        enum: ["elixir_release", "static_site", "process"]
      },
      domain: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 255},
      path_prefix: %OpenApiSpex.Schema{
        type: :string,
        description: "Must start with /",
        maxLength: 255
      },
      exec_command: %OpenApiSpex.Schema{
        type: :string,
        maxLength: 1000,
        description: "Required for elixir_release and process. Must be blank for static_site."
      },
      exec_start_pre: %OpenApiSpex.Schema{
        type: :string,
        maxLength: 1000,
        description: "Optional ExecStartPre command. Must be blank for static_site."
      },
      exec_stop: %OpenApiSpex.Schema{
        type: :string,
        maxLength: 1000,
        description: "Optional ExecStop command. Must be blank for static_site."
      },
      exec_console: %OpenApiSpex.Schema{
        type: :string,
        maxLength: 1000,
        description:
          "Optional explicit remote-console command, for launch commands the automatic start→remote swap cannot handle. Must be blank for static_site."
      },
      env_vars: %OpenApiSpex.Schema{
        type: :object,
        additionalProperties: %OpenApiSpex.Schema{type: :string}
      },
      min_healthy: %OpenApiSpex.Schema{type: :integer, minimum: 1, default: 1},
      health_check: %OpenApiSpex.Schema{
        nullable: true,
        allOf: [HealthCheck],
        description: "Required for elixir_release and process. Must be blank for static_site."
      },
      artifact_source: ArtifactSource
    },
    required: [:name, :type, :domain, :min_healthy, :artifact_source]
  })
end
