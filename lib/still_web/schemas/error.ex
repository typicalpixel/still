defmodule StillWeb.Schemas.Error do
  @moduledoc "Standard error envelope returned for any non-2xx response."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Error",
    type: :object,
    properties: %{
      error: %OpenApiSpex.Schema{
        type: :object,
        properties: %{
          message: %OpenApiSpex.Schema{type: :string},
          detail: %OpenApiSpex.Schema{
            description: "Optional error detail — often a map of field-level validation errors."
          }
        },
        required: [:message]
      }
    },
    required: [:error]
  })
end
