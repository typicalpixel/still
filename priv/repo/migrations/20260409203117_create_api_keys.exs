defmodule Still.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :hashed_key, :binary, null: false
      add :permissions, {:array, :string}, null: false
      add :last_used_at, :utc_datetime_usec
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(updated_at: false)
    end

    create unique_index(:api_keys, [:hashed_key])
    create index(:api_keys, [:user_id])
  end
end
