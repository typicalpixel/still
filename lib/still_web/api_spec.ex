defmodule StillWeb.ApiSpec do
  @moduledoc """
  OpenAPI 3.0 specification for the Still HTTP API. Built at runtime
  from `operation/3` declarations on each controller action and
  schema modules under `StillWeb.Schemas.*` — the spec stays in lockstep
  with the code instead of drifting in a hand-maintained file.

  Served live at `GET /api/openapi`.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias StillWeb.{Endpoint, Router}

  @behaviour OpenApi

  @doc "Builds the live OpenAPI spec from the router and controller annotations."
  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Still API",
        version: "2026-04-09",
        description: ~S"""
        API-first deployment platform for bare metal servers.

        All responses use an envelope shape: `{"data": ...}` on success and
        `{"error": {"message": string, "detail": any}}` on failure. Every
        response echoes the `Still-API-Version` header; clients pin a
        version by sending the same header on requests.
        """
      },
      servers: [Server.from_endpoint(Endpoint)],
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: ~S"""
            Bearer token — either an API key (`still_...`) or a session
            token returned by `POST /api/auth/login`.
            """
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
