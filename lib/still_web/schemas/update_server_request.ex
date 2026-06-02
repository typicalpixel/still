defmodule StillWeb.Schemas.UpdateServerRequest do
  @moduledoc "Body for `PATCH /api/servers/:id`. Only user-editable fields are accepted."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UpdateServerRequest",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 100},
      host: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 255},
      roles: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :string,
          enum: ["controller", "ingress", "application"]
        }
      }
    }
  })
end
