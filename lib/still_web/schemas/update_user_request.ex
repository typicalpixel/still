defmodule StillWeb.Schemas.UpdateUserRequest do
  @moduledoc "Body for `PATCH /api/users/:id`. Password rotation goes through a dedicated endpoint."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UpdateUserRequest",
    type: :object,
    properties: %{
      email: %OpenApiSpex.Schema{type: :string, format: :email, maxLength: 160},
      name: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 100},
      role: %OpenApiSpex.Schema{type: :string, enum: ["admin", "deployer", "viewer"]}
    },
    required: [:email, :name, :role]
  })
end
