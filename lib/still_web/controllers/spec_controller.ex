defmodule StillWeb.SpecController do
  @moduledoc """
  Serves the live OpenAPI 3.0 spec for the Still HTTP API at
  `GET /api/openapi`. The body is rebuilt from `StillWeb.ApiSpec` on
  each request so the spec is always current with the running code.

  Unauthenticated by design — the whole point of the spec is that any
  client (an agent, a dashboard, a script) can introspect the API
  surface to discover what it can do.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  tags(["Meta"])

  operation(:show,
    summary: "Live OpenAPI 3.0 spec for this API",
    description:
      "Built from controller `operation/3` annotations. Always reflects the running code.",
    security: [],
    responses: [
      ok:
        {"OpenAPI 3.0 document", "application/json",
         %OpenApiSpex.Schema{type: :object, additionalProperties: true}}
    ]
  )

  @doc "Returns the live OpenAPI 3.0 spec for the API as JSON."
  def show(%Plug.Conn{} = conn, _params) do
    json(conn, StillWeb.ApiSpec.spec())
  end
end
