defmodule Still.EventsTest do
  use ExUnit.Case, async: true

  alias Still.Events

  describe "server_connected/2" do
    test "broadcasts on servers:lobby" do
      Events.subscribe("servers:lobby")

      Events.server_connected("srv-1", :"agent@10.0.0.3")

      assert_receive {:server_connected, %{server_id: "srv-1", node: :"agent@10.0.0.3"}}
    end
  end

  describe "server_disconnected/1" do
    test "broadcasts on servers:lobby" do
      Events.subscribe("servers:lobby")

      Events.server_disconnected("srv-1")

      assert_receive {:server_disconnected, %{server_id: "srv-1"}}
    end
  end

  describe "deployment_updated/2" do
    test "broadcasts on deployments:<app_name>" do
      Events.subscribe("deployments:my-api")

      Events.deployment_updated("my-api", %{deployment_id: "dep-1", status: :completed})

      assert_receive {:deployment_updated, %{deployment_id: "dep-1", status: :completed}}
    end

    test "does not leak to other application topics" do
      Events.subscribe("deployments:other-app")

      Events.deployment_updated("my-api", %{deployment_id: "dep-1", status: :completed})

      refute_receive {:deployment_updated, _}
    end
  end

  describe "health_transition/2" do
    test "broadcasts on health:<app_name>" do
      Events.subscribe("health:my-api")

      Events.health_transition("my-api", %{from: :healthy, to: :unhealthy})

      assert_receive {:health_transition, %{from: :healthy, to: :unhealthy}}
    end
  end
end
