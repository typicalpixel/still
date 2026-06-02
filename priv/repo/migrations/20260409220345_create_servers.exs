defmodule Still.Repo.Migrations.CreateServers do
  use Ecto.Migration

  def change do
    create table(:servers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :host, :string, null: false
      add :roles, {:array, :string}, null: false
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:servers, [:name])
    create unique_index(:servers, [:host])
  end
end
