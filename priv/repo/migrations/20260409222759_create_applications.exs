defmodule Still.Repo.Migrations.CreateApplications do
  use Ecto.Migration

  def change do
    create table(:applications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string, null: false
      add :domain, :string, null: false
      add :path_prefix, :string
      add :exec_command, :string
      add :env_vars, :map, null: false, default: %{}
      add :health_check, :map
      add :artifact_source, :map, null: false
      add :min_healthy, :integer, null: false, default: 1
      add :maintenance, :boolean, null: false, default: false
      add :maintenance_message, :string

      timestamps()
    end

    create unique_index(:applications, [:name])
  end
end
