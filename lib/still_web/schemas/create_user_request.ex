defmodule StillWeb.Schemas.CreateUserRequest do
  @moduledoc "Body for `POST /api/users`. Same shape as `BootstrapRequest` plus an explicit `role`."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateUserRequest",
    type: :object,
    properties: %{
      email: %OpenApiSpex.Schema{type: :string, format: :email, maxLength: 160},
      name: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 100},
      role: %OpenApiSpex.Schema{type: :string, enum: ["admin", "deployer", "viewer"]},
      password: %OpenApiSpex.Schema{
        type: :string,
        format: :password,
        minLength: 12,
        maxLength: 72
      }
    },
    required: [:email, :name, :role, :password]
  })
end
