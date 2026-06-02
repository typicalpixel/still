defmodule StillWeb.Schemas.Event do
  @moduledoc """
  One entry in the unified live-event ring buffer (best-effort, ~24h
  retention). For durable history, query `/api/audit` instead.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Event",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string},
      type: %OpenApiSpex.Schema{
        type: :string,
        description: ~S"""
        Event type. The dashboard branches on this field to render the
        payload. Examples include `deployment_updated`, `health_transition`,
        `server_connected`, `server_disconnected`, plus the typed audit
        events (`application_created`, `login_succeeded`, etc.).
        """
      },
      at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      payload: %OpenApiSpex.Schema{
        type: :object,
        additionalProperties: true,
        description:
          "Type-specific payload. Audit events also carry `actor_kind` and `actor_label`."
      }
    },
    required: [:id, :type, :at, :payload]
  })
end
