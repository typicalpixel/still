defmodule StillWeb.Schemas.ApplicationServer do
  @moduledoc """
  Join row binding an application to a server with a blue/green port pair.
  Created via assignment, removed via unassignment. The agent runs both
  port slots and serves whichever is currently active.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ApplicationServer",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      application_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      server_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      port_blue: %OpenApiSpex.Schema{type: :integer, nullable: true},
      port_green: %OpenApiSpex.Schema{type: :integer, nullable: true},
      desired_version: %OpenApiSpex.Schema{type: :string, nullable: true},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :application_id, :server_id]
  })
end
