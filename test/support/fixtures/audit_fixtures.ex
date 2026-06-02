defmodule Still.AuditFixtures do
  @moduledoc """
  Test helpers for inserting `audit_events` rows directly. Bypasses
  `Still.Audit.record/2` (and therefore the live emit) so tests can
  pin `inserted_at` for ordering assertions without `Process.sleep`.
  """

  alias Still.Audit.{Actor, AuditEvent}

  @doc """
  Inserts an audit event row. Accepts the same keys as
  `Still.Audit.record/2` plus `:inserted_at` (defaults to
  `DateTime.utc_now/0`) and `:actor` (defaults to `Actor.system/0`).
  """
  def audit_event_fixture(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    actor = Map.get(attrs, :actor, Actor.system())
    inserted_at = Map.get(attrs, :inserted_at, DateTime.utc_now())
    type = Map.fetch!(attrs, :type)

    row_attrs = %{
      type: to_string(type),
      subject_type: maybe_to_string(attrs[:subject_type]),
      subject_id: attrs[:subject_id],
      payload: Map.get(attrs, :payload, %{}),
      before: attrs[:before],
      after: attrs[:after],
      actor_kind: actor.kind,
      actor_label: actor.label,
      actor_user_id: actor.user_id,
      actor_api_key_id: actor.api_key_id,
      actor_server_id: actor.server_id,
      ip: actor.ip,
      user_agent: actor.user_agent
    }

    %AuditEvent{}
    |> AuditEvent.changeset(row_attrs)
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Still.Repo.insert!()
  end

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp maybe_to_string(value) when is_binary(value), do: value
end
