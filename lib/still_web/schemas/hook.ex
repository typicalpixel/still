defmodule StillWeb.Schemas.Hook do
  @moduledoc "Lifecycle hook script run on the agent during deploys/rollbacks."

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Hook",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      application_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      event: %OpenApiSpex.Schema{
        type: :string,
        enum: ["pre_deploy", "release", "post_deploy", "pre_rollback", "post_rollback"]
      },
      script: %OpenApiSpex.Schema{type: :string},
      timeout_ms: %OpenApiSpex.Schema{type: :integer},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :application_id, :event, :script, :timeout_ms]
  })
end
