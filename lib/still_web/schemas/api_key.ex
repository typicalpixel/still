defmodule StillWeb.Schemas.ApiKey do
  @moduledoc """
  API key metadata. Never includes the hashed key bytes; the raw bearer
  is only exposed once, in the create response.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ApiKey",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      name: %OpenApiSpex.Schema{type: :string},
      permissions: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :string,
          enum: ["admin", "deploy", "rollback", "read"]
        }
      },
      last_used_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :name, :permissions]
  })
end
