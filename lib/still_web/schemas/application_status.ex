defmodule StillWeb.Schemas.ApplicationStatus do
  @moduledoc """
  Per-application desired-vs-actual row returned by
  `GET /api/status/applications`.
  """

  require OpenApiSpex

  alias StillWeb.Schemas.AppMetrics

  OpenApiSpex.schema(%{
    title: "ApplicationStatus",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string},
      type: %OpenApiSpex.Schema{
        type: :string,
        enum: ["elixir_release", "static_site", "process"]
      },
      domain: %OpenApiSpex.Schema{type: :string},
      min_healthy: %OpenApiSpex.Schema{type: :integer, minimum: 1},
      healthy_server_count: %OpenApiSpex.Schema{type: :integer, minimum: 0},
      servers: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            server_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
            desired_version: %OpenApiSpex.Schema{type: :string, nullable: true},
            current_version: %OpenApiSpex.Schema{type: :string, nullable: true},
            health: %OpenApiSpex.Schema{type: :string, nullable: true},
            connected: %OpenApiSpex.Schema{type: :boolean}
          },
          required: [:server_id, :connected]
        }
      },
      metrics: AppMetrics
    },
    required: [:name, :type, :domain, :min_healthy, :servers]
  })
end
