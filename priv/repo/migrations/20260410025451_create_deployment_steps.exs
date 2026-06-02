defmodule Still.Repo.Migrations.CreateDeploymentSteps do
  use Ecto.Migration

  def change do
    create table(:deployment_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :deployment_id,
          references(:deployments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :server_id,
          references(:servers, type: :binary_id, on_delete: :delete_all),
          null: false

      add :status, :string, null: false, default: "pending"
      add :error, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:deployment_steps, [:deployment_id, :server_id])
  end
end
