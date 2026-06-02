defmodule StillWeb.Schemas.AuditEvent do
  @moduledoc """
  One row from the durable `audit_events` table. Includes the actor
  identity, optional subject reference, type-specific payload, and
  before/after snapshots when applicable.
  """

  require OpenApiSpex

  alias StillWeb.Schemas.AuditActor

  OpenApiSpex.schema(%{
    title: "AuditEvent",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      type: %OpenApiSpex.Schema{
        type: :string,
        description:
          "Atom name from `Still.Audit.record/2` serialized as a string — e.g. `application_server_unassigned`."
      },
      subject_type: %OpenApiSpex.Schema{type: :string, nullable: true},
      subject_id: %OpenApiSpex.Schema{type: :string, nullable: true},
      payload: %OpenApiSpex.Schema{type: :object, additionalProperties: true},
      before: %OpenApiSpex.Schema{type: :object, additionalProperties: true, nullable: true},
      after: %OpenApiSpex.Schema{type: :object, additionalProperties: true, nullable: true},
      actor: AuditActor,
      at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    },
    required: [:id, :type, :payload, :actor, :at]
  })
end
