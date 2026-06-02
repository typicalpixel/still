defmodule Still.MetricsCollectorTest do
  use ExUnit.Case, async: false

  alias Still.MetricsCollector

  setup do
    start_supervised!({MetricsCollector, history_size: 3})
    :ok
  end

  defp sample(server_id, cpu_pct) do
    %{
      server_id: server_id,
      at: DateTime.utc_now(),
      cpu_pct: cpu_pct,
      mem_pct: 50,
      disk_pct: 60
    }
  end

  describe "record/1 + latest_for/1" do
    test "stores the sample and returns it as latest" do
      MetricsCollector.record(sample("srv-1", 12))
      :sys.get_state(MetricsCollector)

      assert %{cpu_pct: 12} = MetricsCollector.latest_for("srv-1")
    end

    test "overwrites the previous latest on subsequent records" do
      MetricsCollector.record(sample("srv-1", 10))
      MetricsCollector.record(sample("srv-1", 20))
      :sys.get_state(MetricsCollector)

      assert %{cpu_pct: 20} = MetricsCollector.latest_for("srv-1")
    end

    test "returns nil when no sample has been recorded for a server" do
      assert MetricsCollector.latest_for("unknown") == nil
    end
  end

  describe "history_for/1" do
    test "returns empty when no samples have been recorded" do
      assert MetricsCollector.history_for("unknown") == []
    end

    test "grows with each sample, oldest first" do
      MetricsCollector.record(sample("srv-1", 10))
      MetricsCollector.record(sample("srv-1", 20))
      :sys.get_state(MetricsCollector)

      assert [%{cpu_pct: 10}, %{cpu_pct: 20}] = MetricsCollector.history_for("srv-1")
    end

    test "caps at history_size — oldest samples drop off" do
      MetricsCollector.record(sample("srv-1", 1))
      MetricsCollector.record(sample("srv-1", 2))
      MetricsCollector.record(sample("srv-1", 3))
      MetricsCollector.record(sample("srv-1", 4))
      :sys.get_state(MetricsCollector)

      assert [%{cpu_pct: 2}, %{cpu_pct: 3}, %{cpu_pct: 4}] =
               MetricsCollector.history_for("srv-1")
    end

    test "tracks each server independently" do
      MetricsCollector.record(sample("srv-1", 10))
      MetricsCollector.record(sample("srv-2", 90))
      :sys.get_state(MetricsCollector)

      assert [%{cpu_pct: 10}] = MetricsCollector.history_for("srv-1")
      assert [%{cpu_pct: 90}] = MetricsCollector.history_for("srv-2")
    end
  end
end
