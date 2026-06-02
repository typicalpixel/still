defmodule StillWeb.Schemas.DeploymentProgress do
  @moduledoc """
  Per-step progress summary for an in-flight deployment. Embedded inside
  `Deployment` when the response shape includes preloaded steps; null
  on shapes that don't (e.g. the create response).
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DeploymentProgress",
    type: :object,
    properties: %{
      completed_steps: %OpenApiSpex.Schema{type: :integer, minimum: 0},
      total_steps: %OpenApiSpex.Schema{type: :integer, minimum: 0},
      pct: %OpenApiSpex.Schema{
        type: :integer,
        minimum: 0,
        maximum: 100,
        description: "Rounded percentage 0..100."
      }
    },
    required: [:completed_steps, :total_steps, :pct]
  })
end
