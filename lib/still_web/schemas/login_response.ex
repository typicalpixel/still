defmodule StillWeb.Schemas.LoginResponse do
  @moduledoc "200 response for `POST /api/auth/login`."

  require OpenApiSpex

  alias StillWeb.Schemas.User

  OpenApiSpex.schema(%{
    title: "LoginResponse",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          token: %OpenApiSpex.Schema{
            type: :string,
            description: "Bearer session token (url-safe base64, no padding)."
          },
          user: User
        },
        required: [:token, :user]
      }
    },
    required: [:data]
  })
end
