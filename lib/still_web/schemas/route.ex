defmodule StillWeb.Schemas.Route do
  @moduledoc """
  One application's routing entry for external load balancers (BYOLB).
  Does not filter by agent health — external LBs run their own checks.
  """

  require OpenApiSpex

  alias StillWeb.Schemas.RouteUpstream

  OpenApiSpex.schema(%{
    title: "Route",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string},
      type: %OpenApiSpex.Schema{
        type: :string,
        enum: ["elixir_release", "static_site", "process"]
      },
      domain: %OpenApiSpex.Schema{type: :string},
      path_prefix: %OpenApiSpex.Schema{type: :string, nullable: true},
      upstreams: %OpenApiSpex.Schema{type: :array, items: RouteUpstream}
    },
    required: [:name, :type, :domain, :upstreams]
  })
end
