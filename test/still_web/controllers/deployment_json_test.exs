defmodule StillWeb.DeploymentJSONTest do
  use ExUnit.Case, async: true

  alias Still.Applications.Application
  alias Still.Deployments.Deployment
  alias Still.Deployments.DeploymentStep
  alias StillWeb.DeploymentJSON

  @started ~U[2026-04-20 12:00:00.000000Z]
  @finished DateTime.add(@started, 2_000, :millisecond)

  defp sample_deployment do
    %Deployment{
      id: "dep-1",
      application_id: "app-1",
      version: "1.0.0",
      artifact_url: "https://example.com/app.tar.gz",
      status: :completed,
      initiated_by: "user:jane",
      source: "git:main@abc1234",
      started_at: @started,
      completed_at: @finished,
      inserted_at: @started,
      application: %Application{name: "my-api"},
      steps: [
        %DeploymentStep{
          id: "step-1",
          server_id: "srv-1",
          status: :completed,
          error: nil,
          started_at: @started,
          completed_at: @finished
        }
      ]
    }
  end

  describe "deployment/1" do
    test "includes duration_ms computed from the timestamps" do
      assert %{duration_ms: 2_000} = DeploymentJSON.deployment(sample_deployment())
    end

    test "returns nil duration_ms when timestamps are missing" do
      d = %{sample_deployment() | started_at: nil, completed_at: nil}
      assert %{duration_ms: nil} = DeploymentJSON.deployment(d)
    end
  end

  describe "deployment_with_application/1" do
    test "inlines the parent application's name" do
      assert %{application_name: "my-api"} =
               DeploymentJSON.deployment_with_application(sample_deployment())
    end
  end

  describe "deployment_with_steps/1" do
    test "attaches the steps list" do
      assert %{steps: [%{id: "step-1", server_id: "srv-1", status: :completed}]} =
               DeploymentJSON.deployment_with_steps(sample_deployment())
    end
  end

  describe "render/1 (index)" do
    test "wraps each deployment in a data envelope with application_name" do
      assert %{data: [row]} = DeploymentJSON.render([sample_deployment()])
      assert row.application_name == "my-api"
      assert row.duration_ms == 2_000
      refute Map.has_key?(row, :steps)
    end
  end

  describe "render_one/1 (show)" do
    test "attaches steps on a single deployment" do
      assert %{data: %{steps: [_]}} = DeploymentJSON.render_one(sample_deployment())
    end
  end

  describe "render_created/1" do
    test "returns the base shape without steps or application_name" do
      assert %{data: row} = DeploymentJSON.render_created(sample_deployment())
      refute Map.has_key?(row, :steps)
      refute Map.has_key?(row, :application_name)
    end
  end
end
