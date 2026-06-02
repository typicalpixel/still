defmodule StillWeb.Schemas.CreateServerRequest do
  @moduledoc "Body for `POST /api/servers`."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateServerRequest",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 100},
      host: %OpenApiSpex.Schema{
        type: :string,
        description: "IP address or hostname.",
        minLength: 1,
        maxLength: 255
      },
      roles: %OpenApiSpex.Schema{
        type: :array,
        minItems: 1,
        items: %OpenApiSpex.Schema{
          type: :string,
          enum: ["controller", "ingress", "application"]
        }
      }
    },
    required: [:name, :host, :roles]
  })
end
