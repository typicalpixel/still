defmodule StillWeb.Schemas.AppMetrics do
  @moduledoc """
  Rolling Caddy request counts for an application, sampled by the
  controller from the local Caddy's `/metrics` endpoint.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AppMetrics",
    type: :object,
    properties: %{
      window_total: %OpenApiSpex.Schema{
        type: :integer,
        description: "Sum of deltas across all samples in the retention window."
      },
      samples: %OpenApiSpex.Schema{
        type: :array,
        description: "Per-tick samples, oldest first.",
        items: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
            delta: %OpenApiSpex.Schema{
              type: :integer,
              description: "Request count added since the previous sample."
            },
            total: %OpenApiSpex.Schema{
              type: :number,
              description: "Raw Caddy counter value at this tick."
            }
          }
        }
      }
    },
    required: [:window_total, :samples]
  })
end
