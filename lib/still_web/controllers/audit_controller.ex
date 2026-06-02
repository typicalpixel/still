defmodule StillWeb.AuditController do
  @moduledoc """
  Reads the durable audit log — every config mutation, auth event,
  deploy lifecycle transition, and agent-driven state change. Newest
  first, filterable by type / actor / subject / time window.

  Admin-only — audit records carry actor IPs and full before/after
  snapshots of operational rows.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :admin when action in [:index]

  alias Still.Audit
  alias StillWeb.AuditJSON
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope

  tags(["Audit"])

  operation(:index,
    summary: "Durable audit trail",
    description: ~S"""
    Every mutation, auth event, deploy transition, and agent-driven
    state change. Newest first. Includes the full actor identity
    (kind, label, IP, User-Agent) plus before/after snapshots where
    applicable. Admin-only.
    """,
    parameters: [
      type: [in: :query, schema: %OpenApiSpex.Schema{type: :string}],
      actor_user_id: [in: :query, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}],
      actor_api_key_id: [in: :query, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}],
      actor_server_id: [in: :query, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}],
      subject_type: [in: :query, schema: %OpenApiSpex.Schema{type: :string}],
      subject_id: [in: :query, schema: %OpenApiSpex.Schema{type: :string}],
      since: [in: :query, schema: %OpenApiSpex.Schema{type: :string, format: :"date-time"}],
      until: [in: :query, schema: %OpenApiSpex.Schema{type: :string, format: :"date-time"}],
      limit: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 500, default: 50}
      ]
    ],
    responses: [
      ok: {"Audit events", "application/json", Envelope.list(Schemas.AuditEvent)},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc """
  Lists audit events. Filters: `type`, `actor_user_id`,
  `actor_api_key_id`, `actor_server_id`, `subject_type`, `subject_id`,
  `since` (ISO-8601, inclusive), `until` (ISO-8601, exclusive),
  `limit` (1..500, default 50).
  """
  def index(%Plug.Conn{} = conn, params) when is_map(params) do
    json(conn, AuditJSON.render(Audit.list(params)))
  end
end
