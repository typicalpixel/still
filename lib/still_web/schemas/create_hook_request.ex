defmodule StillWeb.Schemas.CreateHookRequest do
  @moduledoc "Body for `POST /api/applications/:application_name/hooks`. One hook per event per application."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "CreateHookRequest",
    type: :object,
    properties: %{
      event: %OpenApiSpex.Schema{
        type: :string,
        enum: ["pre_deploy", "release", "post_deploy", "pre_rollback", "post_rollback"]
      },
      script: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 100_000},
      timeout_ms: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 3_600_000}
    },
    required: [:event, :script, :timeout_ms]
  })
end
