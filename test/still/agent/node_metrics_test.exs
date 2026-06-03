defmodule Still.Agent.NodeMetricsTest do
  use ExUnit.Case, async: false

  alias Still.Agent.NodeMetrics
  alias Still.MetricsCollector

  describe "mem_pct_from/1" do
    test "uses :available_memory when present (excludes reclaimable cache)" do
      # Cache makes free low, but most of it is reclaimable: 80% available.
      data = [system_total_memory: 10_000, free_memory: 3_000, available_memory: 8_000]
      assert NodeMetrics.mem_pct_from(data) == 20
    end

    test "falls back to :free_memory when :available_memory is absent" do
      data = [system_total_memory: 10_000, free_memory: 3_000]
      assert NodeMetrics.mem_pct_from(data) == 70
    end

    test "rounds to a whole integer" do
      data = [system_total_memory: 3, available_memory: 2]
      # 1/3 = 33.33% → 33
      assert NodeMetrics.mem_pct_from(data) == 33
    end

    test "returns nil when :system_total_memory is missing" do
      assert NodeMetrics.mem_pct_from(available_memory: 500) == nil
    end

    test "returns nil when neither :available_memory nor :free_memory is present" do
      assert NodeMetrics.mem_pct_from(system_total_memory: 1_000) == nil
    end

    test "returns nil on non-list input" do
      assert NodeMetrics.mem_pct_from(nil) == nil
      assert NodeMetrics.mem_pct_from(:not_a_list) == nil
    end

    test "returns nil when total is zero" do
      assert NodeMetrics.mem_pct_from(system_total_memory: 0, available_memory: 0) == nil
    end
  end

  describe "disk_pct_from/2" do
    test "picks the longest matching mount for the given path" do
      entries = [
        {~c"/", 100_000_000, 50},
        {~c"/var", 20_000_000, 25}
      ]

      # /var/lib/still should resolve to the /var mount (25% used).
      assert NodeMetrics.disk_pct_from(entries, "/var/lib/still") == 25
    end

    test "returns nil when no mount matches" do
      entries = [{~c"/other", 1_000, 10}]
      assert NodeMetrics.disk_pct_from(entries, "/var/lib/still") == nil
    end

    test "returns nil on empty mount list" do
      assert NodeMetrics.disk_pct_from([], "/var/lib/still") == nil
    end

    test "returns nil on non-list entries" do
      assert NodeMetrics.disk_pct_from(nil, "/var") == nil
    end
  end

  describe "build_sample/1" do
    test "returns a map with the documented keys" do
      assert %{
               server_id: "srv-1",
               at: %DateTime{},
               cpu_pct: _,
               mem_pct: _,
               disk_pct: _
             } = NodeMetrics.build_sample("srv-1")
    end
  end

  describe "init + tick + cast" do
    # Long interval on every test — we fire ticks manually via `send/2`
    # so the timer never actually elapses within a test run.
    @long_interval_ms 60_000

    test "init schedules a tick when server_id is configured" do
      original = Application.get_env(:still, :server_id)
      Application.put_env(:still, :server_id, "srv-init")
      on_exit(fn -> reset_server_id(original) end)

      pid =
        start_supervised!(
          {NodeMetrics, controller_node: Node.self(), interval_ms: @long_interval_ms}
        )

      state = :sys.get_state(pid)
      assert state.server_id == "srv-init"
      assert state.controller == Node.self()
      assert state.interval == @long_interval_ms
    end

    test "init with no server_id leaves state intact but doesn't schedule" do
      original = Application.get_env(:still, :server_id)
      Application.delete_env(:still, :server_id)
      on_exit(fn -> reset_server_id(original) end)

      pid =
        start_supervised!(
          {NodeMetrics, controller_node: Node.self(), interval_ms: @long_interval_ms}
        )

      # handle_info(:tick, %{server_id: nil}) is a documented no-op;
      # force one to confirm nothing crashes.
      send(pid, :tick)
      assert %{server_id: nil} = :sys.get_state(pid)
    end

    test "a fired tick casts a sample to the controller's MetricsCollector" do
      original = Application.get_env(:still, :server_id)
      Application.put_env(:still, :server_id, "srv-tick")
      on_exit(fn -> reset_server_id(original) end)

      start_supervised!(MetricsCollector)

      pid =
        start_supervised!(
          {NodeMetrics, controller_node: Node.self(), interval_ms: @long_interval_ms}
        )

      send(pid, :tick)
      # Drain the process mailbox past the :tick message before reading
      # MetricsCollector state.
      :sys.get_state(pid)
      :sys.get_state(MetricsCollector)

      assert %{server_id: "srv-tick"} = MetricsCollector.latest_for("srv-tick")
    end
  end

  defp reset_server_id(nil), do: Application.delete_env(:still, :server_id)
  defp reset_server_id(value), do: Application.put_env(:still, :server_id, value)
end
