defmodule Still.ProtocolTest do
  use ExUnit.Case, async: true

  alias Still.Protocol.AgentAnnouncement
  alias Still.Protocol.DeployProgress
  alias Still.Protocol.DeployRequest
  alias Still.Protocol.HealthTransition
  alias Still.Protocol.RollbackRequest
  alias Still.Protocol.StopRequest

  describe "DeployRequest" do
    test "constructs with all required fields" do
      req = %DeployRequest{
        application: "my-api",
        type: :elixir_release,
        version: "0.0.1+abc",
        artifact_url: "https://example.com/app.tar.gz",
        domain: "my-api.example.com",
        env_vars: %{},
        health_check: %{path: "/health"},
        hooks: %{},
        port_blue: 20_000,
        port_green: 20_001
      }

      assert req.application == "my-api"
      assert req.exec_command == nil
      assert req.path_prefix == nil
    end

    test "raises on missing required field" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(DeployRequest, %{application: "my-api"})
      end
    end
  end

  describe "RollbackRequest" do
    test "constructs with application" do
      assert %RollbackRequest{application: "my-api"} =
               %RollbackRequest{application: "my-api"}
    end

    test "raises on missing application" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(RollbackRequest, %{})
      end
    end
  end

  describe "StopRequest" do
    test "constructs with application" do
      assert %StopRequest{application: "my-api"} = %StopRequest{application: "my-api"}
    end

    test "raises on missing application" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(StopRequest, %{})
      end
    end
  end

  describe "DeployProgress" do
    test "constructs with all required fields" do
      progress = %DeployProgress{
        server_id: "srv-1",
        application: "my-api",
        version: "0.0.1+abc",
        step: :downloading,
        timestamp: DateTime.utc_now()
      }

      assert progress.step == :downloading
    end

    test "raises on missing required field" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(DeployProgress, %{server_id: "srv-1"})
      end
    end
  end

  describe "HealthTransition" do
    test "constructs with all required fields" do
      transition = %HealthTransition{
        server_id: "srv-1",
        application: "my-api",
        from: :healthy,
        to: :unhealthy,
        timestamp: DateTime.utc_now()
      }

      assert transition.from == :healthy
      assert transition.to == :unhealthy
    end

    test "raises on missing required field" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(HealthTransition, %{server_id: "srv-1", application: "my-api"})
      end
    end
  end

  describe "AgentAnnouncement" do
    test "constructs with all required fields" do
      announcement = %AgentAnnouncement{
        server_id: "srv-1",
        host: "10.0.0.3",
        state: %{applications: []}
      }

      assert announcement.host == "10.0.0.3"
    end

    test "raises on missing required field" do
      assert_raise ArgumentError, ~r/the following keys must also be given/, fn ->
        struct!(AgentAnnouncement, %{server_id: "srv-1"})
      end
    end
  end
end
