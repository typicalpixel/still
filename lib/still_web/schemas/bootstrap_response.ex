defmodule StillWeb.Schemas.BootstrapResponse do
  @moduledoc "201 response for `POST /api/bootstrap`. Returns the new admin and a session token."

  require OpenApiSpex

  alias StillWeb.Schemas.User

  OpenApiSpex.schema(%{
    title: "BootstrapResponse",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          user: User,
          token: %OpenApiSpex.Schema{
            type: :string,
            description: "Session token for the new admin. Bearer it to log straight in."
          }
        },
        required: [:user, :token]
      }
    },
    required: [:data]
  })
end
