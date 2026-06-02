defmodule StillWeb.Schemas.AdminPasswordResetRequest do
  @moduledoc """
  Body for `POST /api/users/:id/password`. Admin authority — no
  current-password check on this endpoint. For self-service password
  changes use `POST /api/auth/me/password` instead.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AdminPasswordResetRequest",
    type: :object,
    properties: %{
      password: %OpenApiSpex.Schema{
        type: :string,
        format: :password,
        minLength: 12,
        maxLength: 72
      }
    },
    required: [:password]
  })
end
