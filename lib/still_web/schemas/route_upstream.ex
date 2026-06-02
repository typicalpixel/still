defmodule StillWeb.Schemas.RouteUpstream do
  @moduledoc "One upstream entry inside a `Route` — host:port plus identity."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "RouteUpstream",
    type: :object,
    properties: %{
      server_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      server_name: %OpenApiSpex.Schema{type: :string},
      host: %OpenApiSpex.Schema{type: :string},
      port: %OpenApiSpex.Schema{type: :integer},
      dial: %OpenApiSpex.Schema{
        type: :string,
        description: "host:port string ready for proxy backends."
      }
    },
    required: [:server_id, :server_name, :host, :port, :dial]
  })
end
