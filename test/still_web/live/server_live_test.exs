defmodule StillWeb.ServerLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.FleetFixtures

  alias Still.AgentConnectionManager
  alias Still.Events
  alias Still.Fleet
  alias Still.MetricsCollector

  setup do
    start_supervised!(AgentConnectionManager)
    start_supervised!(MetricsCollector)
    :ok
  end

  defp agent_report(server_id, apps) do
    %{server_id: server_id, node: :a@h, connected_at: DateTime.utc_now(), applications: apps}
  end

  defp connect_agent(server_id, apps \\ []) do
    AgentConnectionManager.agent_connected(agent_report(server_id, apps))
    :sys.get_state(AgentConnectionManager)
  end

  describe "server detail" do
    setup :register_and_log_in_user

    test "renders a connected server with its apps and resources", %{conn: conn} do
      server = server_fixture(%{name: "srv-1", host: "10.0.0.1", roles: ["ingress"]})

      connect_agent(server.id, [
        %{
          application_name: "api",
          health: :healthy,
          active_slot: :blue,
          current_version: "1.2.3",
          active_port: 4001,
          pid: 99
        }
      ])

      MetricsCollector.record(%{
        server_id: server.id,
        cpu_pct: 42,
        mem_pct: 55,
        disk_pct: 12,
        at: DateTime.utc_now()
      })

      :sys.get_state(MetricsCollector)

      {:ok, _lv, html} = live(conn, ~p"/servers/#{server.id}")

      assert html =~ "srv-1"
      assert html =~ "10.0.0.1"
      assert html =~ "Connected"
      assert html =~ "ingress"
      assert html =~ "api"
      assert html =~ "1.2.3"
      assert html =~ "width: 42%"
    end

    test "shows 'Never connected' and no resources for a fresh server", %{conn: conn} do
      server = server_fixture(%{name: "srv-fresh"})

      {:ok, _lv, html} = live(conn, ~p"/servers/#{server.id}")

      assert html =~ "Never connected"
      assert html =~ "No applications assigned."
      assert html =~ "—"
    end

    test "shows 'Last seen' for a server that reported but is now disconnected", %{conn: conn} do
      server = server_fixture(%{name: "srv-gone"})
      Fleet.record_agent_announcement(server.id, %{}, DateTime.utc_now())

      {:ok, _lv, html} = live(conn, ~p"/servers/#{server.id}")

      assert html =~ "Last seen"
    end

    test "renders not-found for an unknown id", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/servers/#{Ecto.UUID.generate()}")
      assert html =~ "Server not found"
    end

    test "patches only this server's metrics in place", %{conn: conn} do
      server = server_fixture(%{name: "srv-live"})
      connect_agent(server.id)

      {:ok, lv, html} = live(conn, ~p"/servers/#{server.id}")
      refute html =~ "width: 88%"

      Events.node_metrics(%{server_id: server.id, cpu_pct: 88, mem_pct: 20, disk_pct: 5})
      assert render(lv) =~ "width: 88%"

      # A sample for a different server must not touch this page.
      Events.node_metrics(%{server_id: "someone-else", cpu_pct: 99})
      refute render(lv) =~ "width: 99%"
    end

    test "reloads on connect and disconnect", %{conn: conn} do
      server = server_fixture(%{name: "srv-z"})
      {:ok, lv, _html} = live(conn, ~p"/servers/#{server.id}")

      connect_agent(server.id)
      Events.server_connected(server.id, :a@h)
      assert render(lv) =~ "Connected"

      Events.server_disconnected(server.id)
      assert render(lv) =~ "srv-z"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/servers/#{Ecto.UUID.generate()}")

      assert path == ~p"/users/log-in"
    end
  end
end
