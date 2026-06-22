defmodule Still.Repo.Migrations.AddLogToDeploymentSteps do
  use Ecto.Migration

  def change do
    alter table(:deployment_steps) do
      add :log, :text
    end
  end
end
