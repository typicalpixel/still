defmodule StillWeb.Schemas.HealthCheck do
  @moduledoc "Application health check configuration. Embedded inside `Application`."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "HealthCheck",
    type: :object,
    properties: %{
      path: %OpenApiSpex.Schema{type: :string, description: "Must start with /"},
      interval_ms: %OpenApiSpex.Schema{type: :integer, minimum: 1, default: 5000},
      deadline_ms: %OpenApiSpex.Schema{type: :integer, minimum: 1, default: 3000}
    },
    required: [:path]
  })
end
