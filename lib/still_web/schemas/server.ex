defmodule StillWeb.Schemas.Server do
  @moduledoc """
  Persisted server row plus live `status` derived from
  `Still.AgentConnectionManager`.
  """

  require OpenApiSpex

  alias StillWeb.Schemas.ServerMetadata

  OpenApiSpex.schema(%{
    title: "Server",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      name: %OpenApiSpex.Schema{type: :string},
      host: %OpenApiSpex.Schema{type: :string},
      roles: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :string,
          enum: ["controller", "ingress", "application"]
        }
      },
      status: %OpenApiSpex.Schema{type: :string, enum: ["connected", "disconnected"]},
      last_seen_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      metadata: ServerMetadata,
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :name, :host, :roles, :status]
  })
end
