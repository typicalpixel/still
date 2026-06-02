defmodule StillWeb.StatusController do
  @moduledoc """
  Fleet overview and health endpoints. Unlike the CRUD controllers, which
  return pure database rows, the status endpoints are the designated place
  where the **desired state** from the database is merged with the **actual
  state** reported by agents. The merge lives in `Still.Status`; this
  controller just routes it to the JSON shape.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  plug StillWeb.Plugs.Authorize, :read when action in [:servers, :applications]

  alias Still.Status
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope
  alias StillWeb.StatusJSON

  tags(["Status"])

  operation(:index,
    summary: "Fleet overview",
    description: "Includes bootstrap status and the current API version. Unauthenticated.",
    security: [],
    responses: [ok: {"Overview", "application/json", Envelope.single(Schemas.StatusOverview)}]
  )

  @doc "Fleet overview including bootstrap status and API version."
  def index(%Plug.Conn{} = conn, _params) do
    json(conn, StatusJSON.render_overview(Status.overview()))
  end

  operation(:servers,
    summary: "Per-server connectivity and running applications",
    description: ~S"""
    Disconnected servers appear with `connection_status: "disconnected"`
    and an empty `applications` list.
    """,
    responses: [ok: {"Servers", "application/json", Envelope.list(Schemas.ServerStatus)}]
  )

  @doc """
  Per-server connectivity plus the applications each connected agent
  reports as running. Disconnected servers appear with
  `connection_status: "disconnected"` and an empty `applications` list.
  """
  def servers(%Plug.Conn{} = conn, _params) do
    json(conn, StatusJSON.render_servers(Status.servers_with_reports()))
  end

  operation(:applications,
    summary: "Per-application desired-vs-actual view",
    responses: [
      ok: {"Applications", "application/json", Envelope.list(Schemas.ApplicationStatus)}
    ]
  )

  @doc """
  Per-application desired-vs-actual view across the fleet.
  """
  def applications(%Plug.Conn{} = conn, _params) do
    json(conn, StatusJSON.render_applications(Status.applications_with_reports()))
  end
end
