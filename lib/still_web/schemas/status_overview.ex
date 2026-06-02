defmodule StillWeb.Schemas.StatusOverview do
  @moduledoc "Fleet overview returned by `GET /api/status`. Safe to call before bootstrap."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "StatusOverview",
    type: :object,
    properties: %{
      api_version: %OpenApiSpex.Schema{
        type: :string,
        description: "ISO-8601 date pinning the response shape — see `Still-API-Version`."
      },
      bootstrap_required: %OpenApiSpex.Schema{type: :boolean},
      server_count: %OpenApiSpex.Schema{type: :integer, minimum: 0},
      connected_server_count: %OpenApiSpex.Schema{type: :integer, minimum: 0}
    },
    required: [:api_version, :bootstrap_required, :server_count, :connected_server_count]
  })
end
