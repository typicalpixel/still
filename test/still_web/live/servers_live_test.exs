defmodule StillWeb.ServersLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.FleetFixtures

  alias Still.AgentConnectionManager
  alias Still.Events
  alias Still.MetricsCollector

  setup do
    start_supervised!(AgentConnectionManager)
    start_supervised!(MetricsCollector)
    :ok
  end

  defp agent_report(server_id, apps) do
    %{
      server_id: server_id,
      node: :"still_agent@10.0.0.3",
      connected_at: DateTime.utc_now(),
      applications: apps
    }
  end

  defp connect_agent(server_id, apps \\ []) do
    AgentConnectionManager.agent_connected(agent_report(server_id, apps))
    :sys.get_state(AgentConnectionManager)
  end

  describe "servers list" do
    setup :register_and_log_in_user

    test "renders an empty state with no servers", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/servers")

      assert html =~ "Servers"
      assert html =~ "No servers registered yet."
      assert html =~ "0 hosts"
    end

    test "lists servers with status, roles, and app count", %{conn: conn} do
      up = server_fixture(%{name: "srv-up", roles: ["ingress"]})
      _down = server_fixture(%{name: "srv-down"})

      connect_agent(up.id, [
        %{
          application_name: "api",
          health: :healthy,
          active_slot: :blue,
          current_version: "1.0.0",
          active_port: 4001,
          pid: 1
        }
      ])

      {:ok, _lv, html} = live(conn, ~p"/servers")

      assert html =~ "srv-up"
      assert html =~ "srv-down"
      assert html =~ "ingress"
      assert html =~ "2 hosts"
      assert html =~ "1 connected"
      assert html =~ "bg-success"
      assert html =~ "bg-error"
    end

    test "patches a server's metrics in place without a reload", %{conn: conn} do
      a = server_fixture(%{name: "srv-a"})
      b = server_fixture(%{name: "srv-b"})
      connect_agent(a.id)
      connect_agent(b.id)

      {:ok, lv, html} = live(conn, ~p"/servers")
      refute html =~ "width: 95%"

      Events.node_metrics(%{server_id: a.id, cpu_pct: 95, mem_pct: 40, disk_pct: 10})

      assert render(lv) =~ "width: 95%"
    end

    test "reloads on connect, disconnect, and fleet changes", %{conn: conn} do
      server = server_fixture(%{name: "srv-x"})
      {:ok, lv, html} = live(conn, ~p"/servers")
      refute html =~ "bg-success"

      connect_agent(server.id)
      Events.server_connected(server.id, :"still_agent@10.0.0.3")
      assert render(lv) =~ "bg-success"

      Events.server_disconnected(server.id)
      Events.fleet_changed()
      assert render(lv) =~ "srv-x"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/servers")
      assert path == ~p"/users/log-in"
    end
  end
end
