defmodule StillWeb.Schemas.User do
  @moduledoc "A staff account with a role-based permission set."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "User",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      email: %OpenApiSpex.Schema{type: :string, format: :email},
      name: %OpenApiSpex.Schema{type: :string},
      role: %OpenApiSpex.Schema{type: :string, enum: ["admin", "deployer", "viewer"]},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :email, :name, :role]
  })
end
