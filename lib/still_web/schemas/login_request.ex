defmodule StillWeb.Schemas.LoginRequest do
  @moduledoc "Body for `POST /api/auth/login`."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LoginRequest",
    type: :object,
    properties: %{
      email: %OpenApiSpex.Schema{type: :string, format: :email},
      password: %OpenApiSpex.Schema{type: :string, format: :password}
    },
    required: [:email, :password]
  })
end
