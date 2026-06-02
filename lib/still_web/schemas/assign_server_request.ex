defmodule StillWeb.Schemas.AssignServerRequest do
  @moduledoc """
  Body for `POST /api/applications/:application_name/servers`. Ports
  may be specified explicitly; otherwise the next available pair from
  the configured `:auto_port_range` is allocated on that server.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AssignServerRequest",
    type: :object,
    properties: %{
      server_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      port_blue: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 65_535},
      port_green: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 65_535}
    },
    required: [:server_id]
  })
end
