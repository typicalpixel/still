defmodule StillWeb.AuditJSON do
  @moduledoc """
  JSON serialization for audit events. Includes everything operators
  need to answer "who did what when from where" — actor identity, IP,
  User-Agent, and full before/after snapshots.
  """

  alias Still.Audit.AuditEvent

  @doc "Renders a list of audit events for the index endpoint."
  def render(events) when is_list(events) do
    %{data: Enum.map(events, &event/1)}
  end

  @doc "Renders a single audit event."
  def event(%AuditEvent{} = e) do
    %{
      id: e.id,
      type: e.type,
      subject_type: e.subject_type,
      subject_id: e.subject_id,
      payload: e.payload,
      before: e.before,
      after: e.after,
      actor: %{
        kind: e.actor_kind,
        label: e.actor_label,
        user_id: e.actor_user_id,
        api_key_id: e.actor_api_key_id,
        server_id: e.actor_server_id,
        ip: e.ip,
        user_agent: e.user_agent
      },
      at: e.inserted_at
    }
  end
end
