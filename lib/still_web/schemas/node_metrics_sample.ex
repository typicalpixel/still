defmodule StillWeb.Schemas.NodeMetricsSample do
  @moduledoc """
  Latest CPU / memory / disk utilization sample reported by the agent.
  Null when no sample has arrived yet (fresh connection or restarted
  collector).
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "NodeMetricsSample",
    type: :object,
    nullable: true,
    properties: %{
      at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      cpu_pct: %OpenApiSpex.Schema{type: :integer, nullable: true},
      mem_pct: %OpenApiSpex.Schema{type: :integer, nullable: true},
      disk_pct: %OpenApiSpex.Schema{type: :integer, nullable: true}
    }
  })
end
