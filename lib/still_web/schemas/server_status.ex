defmodule StillWeb.Schemas.ServerStatus do
  @moduledoc """
  Per-server status row returned by `GET /api/status/servers` — the
  persisted server fields plus live connection state, latest metrics
  sample, and the agent's per-application reports.
  """

  require OpenApiSpex

  alias StillWeb.Schemas.{NodeMetricsSample, ServerMetadata}

  OpenApiSpex.schema(%{
    title: "ServerStatus",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      name: %OpenApiSpex.Schema{type: :string},
      host: %OpenApiSpex.Schema{type: :string},
      roles: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :string}
      },
      connection_status: %OpenApiSpex.Schema{
        type: :string,
        enum: ["connected", "disconnected"]
      },
      connected_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      last_seen_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      metadata: ServerMetadata,
      metrics: NodeMetricsSample,
      applications: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            application_name: %OpenApiSpex.Schema{type: :string},
            current_version: %OpenApiSpex.Schema{type: :string, nullable: true},
            active_slot: %OpenApiSpex.Schema{
              type: :string,
              enum: ["blue", "green"],
              nullable: true
            },
            active_port: %OpenApiSpex.Schema{type: :integer, nullable: true},
            health: %OpenApiSpex.Schema{type: :string, nullable: true},
            last_health_check_at: %OpenApiSpex.Schema{
              type: :string,
              format: :"date-time",
              nullable: true
            },
            pid: %OpenApiSpex.Schema{type: :integer, nullable: true},
            active_state: %OpenApiSpex.Schema{
              type: :string,
              nullable: true,
              description:
                "systemd's ActiveState — typically `active`, `activating`, `inactive`, `failed`."
            },
            active_enter_at: %OpenApiSpex.Schema{
              type: :string,
              format: :"date-time",
              nullable: true
            }
          },
          required: [:application_name]
        }
      }
    },
    required: [:id, :name, :host, :roles, :connection_status, :applications]
  })
end
