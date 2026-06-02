defmodule StillWeb.StatusControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.CaddyMetricsScraper
  alias Still.MetricsCollector

  import Still.AccountsFixtures
  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  setup do
    # The status controller reads live agent state from
    # AgentConnectionManager's ETS table, live node metrics from
    # MetricsCollector's ETS table, and per-app request counts from
    # CaddyMetricsScraper's ETS table. Start all three for every test.
    start_supervised!(AgentConnectionManager)
    start_supervised!(MetricsCollector)

    start_supervised!(
      {CaddyMetricsScraper, interval_ms: 60_000, http_getter: fn _ -> {:ok, ""} end}
    )

    :ok
  end

  defp sample_agent_report(server_id, app_overrides \\ []) do
    %{
      server_id: server_id,
      node: :"still_agent@10.0.0.3",
      connected_at: DateTime.utc_now(),
      applications: app_overrides
    }
  end

  describe "GET /api/status (public)" do
    test "reports bootstrap_required true before any user exists", %{conn: conn} do
      body = conn |> get("/api/status") |> json_response(200)

      assert body["data"]["bootstrap_required"] == true
      assert body["data"]["api_version"] == StillWeb.APIVersion.current()
      assert body["data"]["server_count"] == 0
      assert body["data"]["connected_server_count"] == 0
    end

    test "reports bootstrap_required false once a user exists", %{conn: conn} do
      _user = user_fixture()

      body = conn |> get("/api/status") |> json_response(200)

      assert body["data"]["bootstrap_required"] == false
    end

    test "is reachable without an Authorization header", %{conn: conn} do
      # No Bearer token set; the route should still return 200.
      assert %{"data" => _} = conn |> get("/api/status") |> json_response(200)
    end

    test "counts connected servers from live agent state", %{conn: conn} do
      srv1 = server_fixture(%{name: "srv-1"})
      srv2 = server_fixture(%{name: "srv-2"})

      AgentConnectionManager.agent_connected(sample_agent_report(srv1.id))
      :sys.get_state(AgentConnectionManager)

      body = conn |> get("/api/status") |> json_response(200)

      assert body["data"]["server_count"] == 2
      # Only srv1 announced — srv2 exists in the DB but hasn't connected.
      assert body["data"]["connected_server_count"] == 1
      # srv2 is here so the assertion above is meaningful.
      assert srv2.id
    end
  end

  describe "authenticated endpoints" do
    setup %{conn: conn} do
      user = user_fixture()

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["admin"]})

      conn = put_req_header(conn, "authorization", "Bearer #{api_key.raw_key}")
      %{conn: conn}
    end

    test "GET /api/status/servers renders disconnected servers with an empty app list", %{
      conn: conn
    } do
      server_fixture(%{name: "srv-1"})

      body = conn |> get("/api/status/servers") |> json_response(200)

      assert [
               %{
                 "name" => "srv-1",
                 "connection_status" => "disconnected",
                 "applications" => [],
                 "connected_at" => nil
               }
             ] = body["data"]
    end

    test "GET /api/status/servers merges live-reported applications for connected servers", %{
      conn: conn
    } do
      server = server_fixture(%{name: "srv-live"})

      app_state = %{
        application_name: "my-api",
        active_slot: :blue,
        current_version: "1.0.0+abc",
        health: :healthy,
        last_health_check_at: DateTime.utc_now()
      }

      AgentConnectionManager.agent_connected(sample_agent_report(server.id, [app_state]))
      :sys.get_state(AgentConnectionManager)

      body = conn |> get("/api/status/servers") |> json_response(200)

      assert [
               %{
                 "name" => "srv-live",
                 "connection_status" => "connected",
                 "applications" => [
                   %{
                     "application_name" => "my-api",
                     "current_version" => "1.0.0+abc",
                     "active_slot" => "blue",
                     "health" => "healthy"
                   }
                 ]
               }
             ] = body["data"]
    end

    test "GET /api/status/servers includes metadata and last_seen_at from the DB", %{
      conn: conn
    } do
      server = server_fixture(%{name: "srv-meta"})

      # Announce with system_info so AgentConnectionManager persists metadata.
      report =
        Map.put(
          sample_agent_report(server.id, []),
          :system_info,
          %{hostname: "bm-ord-01", cpu_count: 8, memory_mb: 32_000}
        )

      AgentConnectionManager.agent_connected(report)
      :sys.get_state(AgentConnectionManager)

      body = conn |> get("/api/status/servers") |> json_response(200)

      [row] = body["data"]
      assert row["metadata"]["hostname"] == "bm-ord-01"
      assert row["metadata"]["cpu_count"] == 8
      assert row["metadata"]["memory_mb"] == 32_000
      assert row["last_seen_at"] != nil
    end

    test "GET /api/status/applications merges desired version vs actual per server", %{
      conn: conn
    } do
      app = application_fixture(%{name: "my-api", min_healthy: 1})

      # Two servers assigned to the same app; only srv-a has a live agent.
      srv_a = server_fixture(%{name: "srv-a"})
      srv_b = server_fixture(%{name: "srv-b"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, srv_a)
      {:ok, _} = Applications.assign_server(Actor.system(), app, srv_b)

      # Stamp desired version on both assignments (what an in-flight deploy does).
      Applications.set_desired_version_for_all(app, "2.0.0")

      # srv-a reports it's running an older version — a visible drift.
      AgentConnectionManager.agent_connected(
        sample_agent_report(srv_a.id, [
          %{
            application_name: "my-api",
            active_slot: :blue,
            current_version: "1.0.0",
            health: :healthy
          }
        ])
      )

      :sys.get_state(AgentConnectionManager)

      body = conn |> get("/api/status/applications") |> json_response(200)

      assert [
               %{
                 "name" => "my-api",
                 "type" => "elixir_release",
                 "min_healthy" => 1,
                 "healthy_server_count" => 1,
                 "servers" => server_views
               }
             ] = body["data"]

      srv_a_view = Enum.find(server_views, &(&1["server_id"] == srv_a.id))
      srv_b_view = Enum.find(server_views, &(&1["server_id"] == srv_b.id))

      # srv-a is live, running an older version than the desired version.
      assert srv_a_view["connected"] == true
      assert srv_a_view["desired_version"] == "2.0.0"
      assert srv_a_view["current_version"] == "1.0.0"
      assert srv_a_view["health"] == "healthy"

      # srv-b has no live agent, so current/health are nil but desired is still set.
      assert srv_b_view["connected"] == false
      assert srv_b_view["desired_version"] == "2.0.0"
      assert is_nil(srv_b_view["current_version"])
      assert is_nil(srv_b_view["health"])
    end

    test "GET /api/status/servers requires authentication" do
      # Using a fresh conn with no Authorization header.
      conn = Phoenix.ConnTest.build_conn()
      assert conn |> get("/api/status/servers") |> json_response(401)
    end
  end
end
