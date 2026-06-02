defmodule StillWeb.Schemas.CreateApiKeyRequest do
  @moduledoc "Body for `POST /api/api_keys`."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateApiKeyRequest",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 100},
      permissions: %OpenApiSpex.Schema{
        type: :array,
        minItems: 1,
        items: %OpenApiSpex.Schema{
          type: :string,
          enum: ["admin", "deploy", "rollback", "read"]
        }
      }
    },
    required: [:name, :permissions]
  })
end
