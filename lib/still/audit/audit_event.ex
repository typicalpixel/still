defmodule Still.Audit.AuditEvent do
  @moduledoc """
  Append-only record of who did what when. Inserted by `Still.Audit.record/2`
  inside the same transaction as the operational mutation it describes,
  so the system cannot end up with unaudited writes.

  Foreign keys to mutable tables (`users`, `api_keys`, `servers`) use
  `ON DELETE SET NULL`. The denormalized `actor_label` keeps the row
  readable after those references are gone.
  """

  use Still.Schema

  import Ecto.Changeset

  alias Still.Accounts.{ApiKey, User}
  alias Still.Audit.Actor
  alias Still.Fleet.Server

  schema "audit_events" do
    field :type, :string
    field :subject_type, :string
    field :subject_id, :string

    field :payload, :map, default: %{}
    field :before, :map
    field :after, :map

    field :actor_kind, Ecto.Enum, values: Actor.kinds()
    field :actor_label, :string
    field :ip, :string
    field :user_agent, :string

    belongs_to :actor_user, User, foreign_key: :actor_user_id
    belongs_to :actor_api_key, ApiKey, foreign_key: :actor_api_key_id
    belongs_to :actor_server, Server, foreign_key: :actor_server_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Builds a changeset for inserting an audit event."
  def changeset(%__MODULE__{} = event, attrs) when is_map(attrs) do
    event
    |> cast(attrs, [
      :type,
      :subject_type,
      :subject_id,
      :payload,
      :before,
      :after,
      :actor_kind,
      :actor_label,
      :actor_user_id,
      :actor_api_key_id,
      :actor_server_id,
      :ip,
      :user_agent
    ])
    |> validate_required([:type, :actor_kind, :actor_label])
    |> validate_length(:type, min: 1, max: 100)
    |> validate_length(:actor_label, min: 1, max: 255)
    |> validate_length(:subject_type, max: 100)
    |> validate_length(:subject_id, max: 255)
    |> validate_length(:ip, max: 45)
    |> validate_length(:user_agent, max: 500)
  end
end
