defmodule Still.Repo.Migrations.CreateApplicationServers do
  use Ecto.Migration

  def change do
    create table(:application_servers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id,
          references(:applications, type: :binary_id, on_delete: :delete_all),
          null: false

      add :server_id,
          references(:servers, type: :binary_id, on_delete: :delete_all),
          null: false

      add :port_blue, :integer, null: false
      add :port_green, :integer, null: false
      add :desired_version, :string

      timestamps()
    end

    create unique_index(:application_servers, [:application_id, :server_id])
    create unique_index(:application_servers, [:server_id, :port_blue])
    create unique_index(:application_servers, [:server_id, :port_green])
  end
end
