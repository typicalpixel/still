defmodule StillWeb.Schemas.AuditActor do
  @moduledoc """
  Identity attached to every `AuditEvent`. The `kind` discriminator
  picks which of the per-kind ids (`user_id` / `api_key_id` /
  `server_id`) is populated. `label` is denormalized at write time so
  audit rows stay readable after the underlying user/key/server is
  deleted.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AuditActor",
    type: :object,
    properties: %{
      kind: %OpenApiSpex.Schema{
        type: :string,
        enum: ["user", "api_key", "agent", "anonymous", "system"]
      },
      label: %OpenApiSpex.Schema{type: :string},
      user_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true},
      api_key_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true},
      server_id: %OpenApiSpex.Schema{type: :string, format: :uuid, nullable: true},
      ip: %OpenApiSpex.Schema{type: :string, nullable: true},
      user_agent: %OpenApiSpex.Schema{type: :string, nullable: true}
    },
    required: [:kind, :label]
  })
end
