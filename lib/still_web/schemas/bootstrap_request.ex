defmodule StillWeb.Schemas.BootstrapRequest do
  @moduledoc "Body for `POST /api/bootstrap`. Creates the first admin."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BootstrapRequest",
    type: :object,
    properties: %{
      email: %OpenApiSpex.Schema{type: :string, format: :email},
      name: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 100},
      password: %OpenApiSpex.Schema{
        type: :string,
        format: :password,
        minLength: 12,
        maxLength: 72
      }
    },
    required: [:email, :name, :password]
  })
end
