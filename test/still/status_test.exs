defmodule Still.StatusTest do
  use Still.DataCase, async: false

  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.CaddyMetricsScraper
  alias Still.MetricsCollector
  alias Still.Status

  import Still.AccountsFixtures
  import Still.AgentFixtures
  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  setup do
    start_supervised!(AgentConnectionManager)
    start_supervised!(MetricsCollector)
    # Scraper with a stub getter that returns no metrics. Tests that
    # care about per-app request numbers push their own payload and
    # call scrape_now/0.
    start_supervised!(
      {CaddyMetricsScraper, interval_ms: 60_000, http_getter: fn _ -> {:ok, ""} end}
    )

    :ok
  end

  describe "overview/0" do
    test "reports zero servers and bootstrap_required true before any user exists" do
      assert %{bootstrap_required: true, server_count: 0, connected_server_count: 0} =
               Status.overview()
    end

    test "tracks connected agent count via AgentConnectionManager" do
      user_fixture()
      server = server_fixture()

      AgentConnectionManager.agent_connected(agent_report_fixture(server_id: server.id))
      :sys.get_state(AgentConnectionManager)

      assert %{bootstrap_required: false, server_count: 1, connected_server_count: 1} =
               Status.overview()
    end
  end

  describe "servers_with_reports/0" do
    test "pairs every server with its latest report or nil" do
      srv_a = server_fixture(%{name: "a"})
      srv_b = server_fixture(%{name: "b"})

      AgentConnectionManager.agent_connected(agent_report_fixture(server_id: srv_a.id))
      :sys.get_state(AgentConnectionManager)

      # Fleet.list_servers orders by name. srv_a just got a fresh
      # last_seen_at + metadata stamp from the announce, so don't pin
      # the full struct — match by id.
      assert [
               %{server: %{id: a_id}, report: %{server_id: a_rep}, metrics: nil},
               %{server: %{id: b_id}, report: nil, metrics: nil}
             ] = Status.servers_with_reports()

      assert a_id == srv_a.id
      assert a_rep == srv_a.id
      assert b_id == srv_b.id
    end

    test "includes the latest metrics sample when the collector has recorded one" do
      srv = server_fixture()

      MetricsCollector.record(%{
        server_id: srv.id,
        at: DateTime.utc_now(),
        cpu_pct: 12,
        mem_pct: 42,
        disk_pct: 51
      })

      :sys.get_state(MetricsCollector)

      assert [%{server: %{id: id}, metrics: %{cpu_pct: 12, mem_pct: 42, disk_pct: 51}}] =
               Status.servers_with_reports()

      assert id == srv.id
    end
  end

  describe "applications_with_reports/0" do
    test "pairs each assignment with the matching live application state" do
      app = application_fixture(%{name: "my-api", min_healthy: 1})
      server = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      AgentConnectionManager.agent_connected(
        agent_report_fixture(
          server_id: server.id,
          applications: [
            reported_application_fixture(application_name: "my-api", current_version: "1.0.0")
          ]
        )
      )

      :sys.get_state(AgentConnectionManager)

      [
        %{application: %{id: app_id}, assigned: [{_row, _report, live}]}
      ] = Status.applications_with_reports()

      assert app_id == app.id
      assert live.current_version == "1.0.0"
      assert live.health == :healthy
    end

    test "emits {row, nil, nil} for servers whose agent is disconnected" do
      app = application_fixture(%{name: "my-api", min_healthy: 1})
      server = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      [
        %{application: %{id: app_id}, assigned: [{_row, nil, nil}]}
      ] = Status.applications_with_reports()

      assert app_id == app.id
    end

    test "includes per-application Caddy request metrics" do
      app = application_fixture(%{name: "my-api", domain: "api.example.com"})
      server = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      # Swap the setup's empty-getter scraper for one that yields two
      # successive counter values for the app's host.
      stop_supervised!(CaddyMetricsScraper)

      start_supervised!(
        {CaddyMetricsScraper,
         interval_ms: 60_000,
         http_getter:
           seeded_getter([
             metrics_payload("api.example.com", 100),
             metrics_payload("api.example.com", 250)
           ])}
      )

      :ok = CaddyMetricsScraper.scrape_now()
      :ok = CaddyMetricsScraper.scrape_now()

      assert [%{metrics: metrics}] = Status.applications_with_reports()
      # First scrape establishes baseline (delta 0); second records +150.
      assert metrics.window_total == 150
      assert length(metrics.samples) == 2
    end
  end

  # Builds a valid per-host caddy_http_requests_total line body.
  defp metrics_payload(host, count) do
    """
    # HELP caddy_http_requests_total Counter of HTTP(S) requests made.
    # TYPE caddy_http_requests_total counter
    caddy_http_requests_total{code="200",handler="reverse_proxy",host="#{host}",method="GET",server="still"} #{count}
    """
  end

  # Returns an http_getter that yields the given payloads in order —
  # subsequent scrapes after the list runs out get an empty body.
  defp seeded_getter(payloads) do
    {:ok, agent} = Agent.start_link(fn -> payloads end)

    fn _url ->
      body =
        Agent.get_and_update(agent, fn
          [head | rest] -> {head, rest}
          [] -> {"", []}
        end)

      {:ok, body}
    end
  end
end
