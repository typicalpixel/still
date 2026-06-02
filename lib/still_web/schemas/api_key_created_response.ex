defmodule StillWeb.Schemas.ApiKeyCreatedResponse do
  @moduledoc """
  201 response for `POST /api/api_keys`. Includes the raw bearer token
  in `data.raw_key` — shown once, never returned again.
  """

  require OpenApiSpex

  alias StillWeb.Schemas.ApiKey

  OpenApiSpex.schema(%{
    title: "ApiKeyCreatedResponse",
    type: :object,
    properties: %{
      data: %OpenApiSpex.Schema{
        allOf: [
          ApiKey,
          %OpenApiSpex.Schema{
            type: :object,
            properties: %{
              raw_key: %OpenApiSpex.Schema{
                type: :string,
                description: "Full API key (prefix `still_`). Shown once; store it now."
              }
            },
            required: [:raw_key]
          }
        ]
      }
    },
    required: [:data]
  })
end
