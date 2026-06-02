defmodule StillWeb.Schemas.UpdateHookRequest do
  @moduledoc "Body for `PATCH /api/applications/:application_name/hooks/:id`. Event is immutable."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "UpdateHookRequest",
    type: :object,
    properties: %{
      script: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 100_000},
      timeout_ms: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 3_600_000}
    }
  })
end
