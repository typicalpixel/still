defmodule Still.Repo.Migrations.CreateHooks do
  use Ecto.Migration

  def change do
    create table(:hooks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :application_id,
          references(:applications, type: :binary_id, on_delete: :delete_all),
          null: false

      add :event, :string, null: false
      add :script, :text, null: false
      add :timeout_ms, :integer, null: false

      timestamps()
    end

    create unique_index(:hooks, [:application_id, :event])
  end
end
