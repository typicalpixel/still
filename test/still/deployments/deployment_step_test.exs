defmodule Still.Deployments.DeployStepTest do
  use Still.DataCase, async: false

  alias Still.Deployments.DeploymentStep

  describe "creation_changeset/2" do
    test "is valid with deployment_id and server_id" do
      changeset =
        DeploymentStep.creation_changeset(%DeploymentStep{}, %{
          deployment_id: Ecto.UUID.generate(),
          server_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end

    test "requires deployment_id and server_id" do
      changeset = DeploymentStep.creation_changeset(%DeploymentStep{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.deployment_id
      assert "can't be blank" in errors.server_id
    end

    test "defaults status to :pending on a fresh struct" do
      assert %DeploymentStep{status: :pending} = %DeploymentStep{}
    end
  end

  describe "statuses/0" do
    test "returns the known status set in agent state machine order" do
      assert DeploymentStep.statuses() == [
               :pending,
               :downloading,
               :unpacking,
               :starting,
               :health_checking,
               :switching,
               :stopping_old,
               :cleanup,
               :completed,
               :failed
             ]
    end
  end
end
