defmodule StillWeb.Schemas.UpdateProfileRequest do
  @moduledoc "Body for `PATCH /api/auth/me`. Self-service profile fields only."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UpdateProfileRequest",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 100}
    },
    required: [:name]
  })
end
