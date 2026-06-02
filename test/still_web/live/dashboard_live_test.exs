defmodule StillWeb.DashboardLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.CaddyMetricsScraper
  alias Still.EventLog
  alias Still.Events
  alias Still.MetricsCollector

  setup do
    # The dashboard reads applications-with-reports (live agent state + Caddy
    # request metrics) and the fleet overview, all ETS-backed by these workers.
    start_supervised!(AgentConnectionManager)
    start_supervised!(MetricsCollector)

    start_supervised!(
      {CaddyMetricsScraper, interval_ms: 60_000, http_getter: fn _ -> {:ok, ""} end}
    )

    :ok
  end

  defp connect_agent(server_id, apps) do
    AgentConnectionManager.agent_connected(%{
      server_id: server_id,
      node: :a@h,
      connected_at: DateTime.utc_now(),
      applications: apps
    })

    :sys.get_state(AgentConnectionManager)
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(
      Still.PubSub,
      "events:lobby",
      {:event_recorded, Map.put(event, :at, DateTime.utc_now())}
    )
  end

  describe "dashboard" do
    setup :register_and_log_in_user

    setup do
      # Start the event log after login so registration's audit event isn't
      # captured — the activity feed begins empty.
      start_supervised!(EventLog)
      :ok
    end

    test "renders empty states with a healthy fleet footer", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "No applications yet."
      assert html =~ "No activity yet."
      assert html =~ "0 applications on 0 hosts"
      assert html =~ "last event —"
      assert html =~ "0 of 0 servers online"
    end

    test "warns in the footer when not every server is online", %{conn: conn} do
      _server = server_fixture(%{name: "s1"})

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "0 of 1 servers online"
      assert html =~ "bg-warning"
    end

    test "lists applications with their common version and health", %{conn: conn} do
      app = application_fixture(%{name: "api", min_healthy: 1})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)
      Applications.set_desired_version_for_all(app, "1.0.0")

      connect_agent(server.id, [
        %{application_name: "api", health: :healthy, current_version: "1.0.0", active_slot: :blue}
      ])

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "api"
      assert html =~ "1.0.0"
      assert html =~ "healthy"
      assert html =~ "1 applications on 1 hosts"
    end

    test "prepends activity and reloads apps on deploy events", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      broadcast_event(%{
        id: "e1",
        type: :deployment_updated,
        payload: %{application_name: "api", status: :completed, deployment_id: "d1"}
      })

      assert render(lv) =~ "api deploy completed"

      broadcast_event(%{id: "e2", type: :server_connected, payload: %{server_id: "s1"}})
      assert render(lv) =~ "s1 connected"

      # A per-step ping carries no top-level status, so it's dropped from the
      # feed — the page stays intact.
      broadcast_event(%{
        id: "e3",
        type: :deployment_updated,
        payload: %{server_id: "s1", step_status: :completed}
      })

      assert render(lv) =~ "Recent activity"
    end

    test "reloads on connect, disconnect, and fleet changes", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      Events.server_connected("ghost", :a@h)
      Events.server_disconnected("ghost")
      Events.fleet_changed()

      assert render(lv) =~ "servers online"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/")
      assert path == ~p"/users/log-in"
    end
  end
end
