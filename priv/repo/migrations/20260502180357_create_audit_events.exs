defmodule Still.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :type, :string, null: false
      add :subject_type, :string
      add :subject_id, :string

      add :payload, :map, null: false, default: %{}
      add :before, :map
      add :after, :map

      add :actor_kind, :string, null: false
      add :actor_label, :string, null: false

      add :actor_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)

      add :actor_api_key_id,
          references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      add :actor_server_id,
          references(:servers, type: :binary_id, on_delete: :nilify_all)

      add :ip, :string
      add :user_agent, :string

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_events, [:inserted_at])
    create index(:audit_events, [:type, :inserted_at])
    create index(:audit_events, [:actor_user_id, :inserted_at])
    create index(:audit_events, [:actor_api_key_id, :inserted_at])
    create index(:audit_events, [:actor_server_id, :inserted_at])
    create index(:audit_events, [:subject_type, :subject_id, :inserted_at])
  end
end
