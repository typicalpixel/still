defmodule Still.Repo.Migrations.AddExecConsoleToApplications do
  use Ecto.Migration

  def change do
    alter table(:applications) do
      add :exec_console, :string
    end
  end
end
