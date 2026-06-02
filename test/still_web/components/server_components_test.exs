defmodule StillWeb.ServerComponentsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import StillWeb.ServerComponents

  describe "server_slot_dot/1 and server_slot_label/1" do
    test "disconnected slots read neutral / unreachable" do
      slot = %{connected: false, health: :healthy, current_version: "1.0"}
      assert server_slot_dot(slot) == :neutral
      assert server_slot_label(slot) == "unreachable"
    end

    test "health probes drive the tone and label" do
      assert server_slot_dot(%{connected: true, health: :degraded, current_version: "1.0"}) ==
               :warn

      assert server_slot_dot(%{connected: true, health: :unhealthy, current_version: "1.0"}) ==
               :danger

      assert server_slot_dot(%{connected: true, health: :healthy, current_version: "1.0"}) ==
               :healthy

      assert server_slot_label(%{connected: true, health: :degraded, current_version: "1.0"}) ==
               "degraded"
    end

    test "no-probe slots fall back to deployed bits" do
      assert server_slot_dot(%{connected: true, health: nil, current_version: "1.0"}) == :healthy
      assert server_slot_dot(%{connected: true, health: nil, current_version: "—"}) == :neutral

      assert server_slot_label(%{connected: true, health: nil, current_version: "1.0"}) ==
               "running"

      assert server_slot_label(%{connected: true, health: nil, current_version: "—"}) ==
               "not deployed"
    end
  end

  describe "app_fleet/1" do
    test "renders assigned servers with a drift flag, or an empty notice" do
      assigns = %{
        fleet: [
          %{
            server_id: "s1",
            server_name: "web-1",
            host: "10.0.0.1",
            desired_version: "2.0",
            current_version: "1.0",
            health: :healthy,
            connected: true,
            last_seen: ~U[2026-01-01 00:00:00Z]
          }
        ]
      }

      html = rendered_to_string(~H|<.app_fleet fleet={@fleet} />|)
      assert html =~ "web-1"
      assert html =~ "drift"

      assigns = %{fleet: []}
      assert rendered_to_string(~H|<.app_fleet fleet={@fleet} />|) =~ "No servers assigned."
    end
  end
end
