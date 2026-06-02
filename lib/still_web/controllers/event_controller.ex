defmodule StillWeb.EventController do
  @moduledoc """
  Reads the unified event stream — deploys, health transitions, server
  connect/disconnect — newest first. Powers the dashboard's recent
  activity feed.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :read when action in [:index]

  alias Still.EventLog
  alias StillWeb.EventJSON
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope

  tags(["Events"])

  operation(:index,
    summary: "Recent fleet activity",
    description: ~S"""
    In-memory ring buffer of live events (deploy transitions, health
    transitions, server connect/disconnect, audit emits). Best-effort,
    ~24h retention with a 50k burst cap. Not durable — controller
    restart clears the log. For durable history query `/api/audit`.
    """,
    parameters: [
      type: [in: :query, schema: %OpenApiSpex.Schema{type: :string}],
      before: [in: :query, schema: %OpenApiSpex.Schema{type: :string, format: :"date-time"}],
      limit: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 500, default: 50}
      ]
    ],
    responses: [ok: {"Events", "application/json", Envelope.list(Schemas.Event)}]
  )

  @doc """
  Lists recent events. Filterable by `type`, `before` (ISO-8601), and
  `limit` (1..500, default 50).
  """
  def index(%Plug.Conn{} = conn, params) when is_map(params) do
    json(conn, EventJSON.render(EventLog.list(params)))
  end
end
