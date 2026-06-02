defmodule Still.CaddyMetricsScraperTest do
  use Still.DataCase, async: false

  alias Still.CaddyMetricsScraper

  import Still.ApplicationsFixtures

  describe "parse_host_totals/1" do
    test "sums caddy_http_requests_total counters grouped by host label" do
      body = """
      # HELP caddy_http_requests_total Counter.
      # TYPE caddy_http_requests_total counter
      caddy_http_requests_total{code="200",host="api.example.com",method="GET",server="still"} 42
      caddy_http_requests_total{code="500",host="api.example.com",method="GET",server="still"} 3
      caddy_http_requests_total{code="200",host="www.example.com",method="GET",server="still"} 17
      """

      assert %{
               "api.example.com" => 45.0,
               "www.example.com" => 17.0
             } = CaddyMetricsScraper.parse_host_totals(body)
    end

    test "ignores comment lines and unrelated metrics" do
      body = """
      # HELP unrelated something
      caddy_http_requests_in_flight{server="still"} 2
      caddy_http_requests_total{host="a",code="200"} 1
      """

      assert CaddyMetricsScraper.parse_host_totals(body) == %{"a" => 1.0}
    end

    test "ignores caddy_http_requests_total samples without a host label" do
      body = ~s(caddy_http_requests_total{code="200",server="still"} 99\n)
      assert CaddyMetricsScraper.parse_host_totals(body) == %{}
    end

    test "handles floats and scientific notation" do
      body =
        ~s(caddy_http_requests_total{host="a"} 1.5\n) <>
          ~s(caddy_http_requests_total{host="b"} 2e2\n)

      assert %{"a" => 1.5, "b" => 200.0} = CaddyMetricsScraper.parse_host_totals(body)
    end

    test "returns an empty map on empty input" do
      assert CaddyMetricsScraper.parse_host_totals("") == %{}
    end

    test "ignores samples where the numeric value is shaped like a number but isn't one" do
      # `[0-9eE.+-]+` accepts `.+.`, which Float.parse rejects.
      body = ~s(caddy_http_requests_total{host="a"} .+.\n)
      assert CaddyMetricsScraper.parse_host_totals(body) == %{}
    end
  end

  describe "scraping loop" do
    setup do
      # Fresh app so its domain matches the injected host label.
      app =
        application_fixture(%{
          name: "metrics-test-#{System.unique_integer([:positive])}",
          domain: "metrics.test"
        })

      %{app: app}
    end

    test "baseline counter emits a zero-delta sample", %{app: app} do
      start_with_payloads([~s(caddy_http_requests_total{host="metrics.test"} 100\n)])
      :ok = CaddyMetricsScraper.scrape_now()

      assert [%{delta: 0, total: 100.0}] = CaddyMetricsScraper.history_for(app.name)
      assert CaddyMetricsScraper.window_total(app.name) == 0
    end

    test "second scrape records the delta", %{app: app} do
      start_with_payloads([
        ~s(caddy_http_requests_total{host="metrics.test"} 100\n),
        ~s(caddy_http_requests_total{host="metrics.test"} 275\n)
      ])

      :ok = CaddyMetricsScraper.scrape_now()
      :ok = CaddyMetricsScraper.scrape_now()

      assert [%{delta: 0, total: 100.0}, %{delta: 175, total: 275.0}] =
               CaddyMetricsScraper.history_for(app.name)

      assert CaddyMetricsScraper.window_total(app.name) == 175
    end

    test "treats a counter reset as a new baseline (no negative deltas)", %{app: app} do
      start_with_payloads([
        ~s(caddy_http_requests_total{host="metrics.test"} 500\n),
        ~s(caddy_http_requests_total{host="metrics.test"} 50\n)
      ])

      :ok = CaddyMetricsScraper.scrape_now()
      :ok = CaddyMetricsScraper.scrape_now()

      deltas =
        app.name
        |> CaddyMetricsScraper.history_for()
        |> Enum.map(& &1.delta)

      assert deltas == [0, 0]
    end

    test "history_size caps the sample window", %{app: app} do
      start_with_payloads(
        for n <- 1..5 do
          ~s(caddy_http_requests_total{host="metrics.test"} #{n * 10}\n)
        end,
        history_size: 3
      )

      for _ <- 1..5 do
        :ok = CaddyMetricsScraper.scrape_now()
      end

      assert length(CaddyMetricsScraper.history_for(app.name)) == 3
    end

    test "apps without a matching host are still tracked with zero deltas", %{app: app} do
      other =
        application_fixture(%{
          name: "unmapped-#{System.unique_integer([:positive])}",
          domain: "nope.example.com"
        })

      start_with_payloads([~s(caddy_http_requests_total{host="#{app.domain}"} 10\n)])
      :ok = CaddyMetricsScraper.scrape_now()
      :ok = CaddyMetricsScraper.scrape_now()

      # The app matching the payload records a baseline plus a zero
      # delta (total unchanged between the two scrapes).
      [%{delta: 0}, %{delta: 0}] = CaddyMetricsScraper.history_for(app.name)

      # The app with no matching host has a baseline of 0 from the
      # map default and subsequent scrapes stay at 0.
      [%{delta: 0, total: 0}, %{delta: 0, total: 0}] = CaddyMetricsScraper.history_for(other.name)
    end

    test "latest_for/1 returns the most recent sample", %{app: app} do
      start_with_payloads([
        ~s(caddy_http_requests_total{host="metrics.test"} 10\n),
        ~s(caddy_http_requests_total{host="metrics.test"} 30\n)
      ])

      :ok = CaddyMetricsScraper.scrape_now()
      :ok = CaddyMetricsScraper.scrape_now()

      assert %{delta: 20, total: 30.0} = CaddyMetricsScraper.latest_for(app.name)
    end

    test "latest_for/1 returns nil for an unknown app" do
      start_with_payloads([""])
      assert CaddyMetricsScraper.latest_for("nonexistent") == nil
    end
  end

  describe "scrape failures" do
    @tag :capture_log
    test "an http error leaves the table unchanged" do
      start_supervised!(
        {CaddyMetricsScraper,
         interval_ms: 60_000, http_getter: fn _ -> {:error, :econnrefused} end}
      )

      :ok = CaddyMetricsScraper.scrape_now()
      assert CaddyMetricsScraper.history_for("anything") == []
    end
  end

  describe "timer-driven scrape" do
    test "a :tick message fires a scrape through the same path" do
      app =
        application_fixture(%{
          name: "tick-#{System.unique_integer([:positive])}",
          domain: "tick.example.com"
        })

      pid = start_with_payloads([~s(caddy_http_requests_total{host="tick.example.com"} 77\n)])

      send(pid, :tick)
      # Drain the process mailbox past the :tick so the scrape and
      # ETS insert have finished before we read.
      :sys.get_state(pid)

      assert [%{total: 77.0}] = CaddyMetricsScraper.history_for(app.name)
    end
  end

  defp start_with_payloads(payloads, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> payloads end)

    getter = fn _url ->
      body =
        Agent.get_and_update(agent, fn
          [head | rest] -> {head, rest}
          [] -> {"", []}
        end)

      {:ok, body}
    end

    history_size = Keyword.get(opts, :history_size, 1440)

    start_supervised!(
      {CaddyMetricsScraper, interval_ms: 60_000, history_size: history_size, http_getter: getter}
    )
  end
end
