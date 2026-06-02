defmodule StillWeb.Schemas.DeploymentStep do
  @moduledoc "Per-server step within a deployment, as reported by the agent."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "DeploymentStep",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      server_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      status: %OpenApiSpex.Schema{
        type: :string,
        enum: ["pending", "in_progress", "completed", "failed"]
      },
      error: %OpenApiSpex.Schema{type: :string, nullable: true},
      started_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      completed_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true}
    },
    required: [:id, :server_id, :status]
  })
end
