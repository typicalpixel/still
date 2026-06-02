defmodule StillWeb.Schemas.ChangeMyPasswordRequest do
  @moduledoc "Body for `POST /api/auth/me/password`. Requires the current password."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ChangeMyPasswordRequest",
    type: :object,
    properties: %{
      current_password: %OpenApiSpex.Schema{type: :string, format: :password},
      password: %OpenApiSpex.Schema{
        type: :string,
        format: :password,
        minLength: 12,
        maxLength: 72
      }
    },
    required: [:current_password, :password]
  })
end
