defmodule Still.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:deployments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id,
          references(:applications, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :string, null: false
      add :artifact_url, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :initiated_by, :string, null: false
      add :source, :string
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps()
    end

    create index(:deployments, [:application_id])
    create index(:deployments, [:application_id, :inserted_at])
  end
end
