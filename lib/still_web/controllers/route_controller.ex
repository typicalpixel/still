defmodule StillWeb.RouteController do
  @moduledoc """
  The routing registry endpoint.

  Returns the set of applications and the agents they run on, in a
  shape external load balancers can consume to generate their backend
  config: Caddy's `http` dynamic upstreams module, nginx + confd,
  HAProxy + consul-template, and so on.

  The endpoint does NOT filter by agent health — external LBs run
  their own health checks and the separation of "which agents *are*
  assigned to this app" (semi-static, Still's answer) from "which are
  healthy right now" (runtime, LB's answer) is the right one.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  plug StillWeb.Plugs.Authorize, :read when action in [:index]

  alias Still.Applications
  alias StillWeb.RouteJSON
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope

  tags(["Routes"])

  operation(:index,
    summary: "Routing registry for external load balancers (BYOLB)",
    description: ~S"""
    Returns one entry per application with the upstream `(host, port)`
    pairs an LB needs to reach the running fleet. Does **not** filter
    by agent health — external LBs run their own health checks.
    """,
    responses: [ok: {"Routes", "application/json", Envelope.list(Schemas.Route)}]
  )

  def index(%Plug.Conn{} = conn, _params) do
    json(conn, RouteJSON.render(Applications.list_routes()))
  end
end
