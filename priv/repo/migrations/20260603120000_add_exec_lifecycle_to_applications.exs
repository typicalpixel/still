defmodule Still.Repo.Migrations.AddExecLifecycleToApplications do
  use Ecto.Migration

  def change do
    alter table(:applications) do
      add :exec_start_pre, :string
      add :exec_stop, :string
    end
  end
end
