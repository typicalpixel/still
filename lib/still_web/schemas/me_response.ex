defmodule StillWeb.Schemas.MeResponse do
  @moduledoc "200 response for `GET /api/auth/me`."

  require OpenApiSpex

  alias StillWeb.Schemas.User

  OpenApiSpex.schema(%{
    title: "MeResponse",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{user: User},
        required: [:user]
      }
    },
    required: [:data]
  })
end
