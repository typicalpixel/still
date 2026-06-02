defmodule Still.EventLogTest do
  use ExUnit.Case, async: false

  alias Still.EventLog

  import Still.EventFixtures

  defp wait_for_processing do
    :sys.get_state(EventLog)
  end

  defp table_size, do: :ets.info(:event_log, :size)

  describe "record/1 + list/1" do
    setup do
      start_supervised!(EventLog)
      :ok
    end

    test "records an event and returns it" do
      EventLog.record(event_fixture(type: :server_connected, payload: %{server_id: "srv-1"}))
      wait_for_processing()

      assert [%{type: :server_connected, payload: %{server_id: "srv-1"}}] = EventLog.list()
    end

    test "returns events newest first" do
      now = DateTime.utc_now()
      older = DateTime.add(now, -60, :second)

      EventLog.record(event_fixture(payload: %{server_id: "old"}, at: older))
      EventLog.record(event_fixture(payload: %{server_id: "new"}, at: now))
      wait_for_processing()

      assert [%{payload: %{server_id: "new"}}, %{payload: %{server_id: "old"}}] =
               EventLog.list()
    end

    test "assigns an id and an at_us timestamp to every stored event" do
      EventLog.record(event_fixture(payload: %{server_id: "srv-1"}))
      wait_for_processing()

      [event] = EventLog.list()
      assert is_binary(event.id)
      assert is_integer(event.at_us)
    end

    test "returns an empty list when nothing has been recorded" do
      assert EventLog.list() == []
    end
  end

  describe "time-based retention" do
    test "evicts events older than retention_ms on each insert" do
      start_supervised!({EventLog, retention_ms: 1_000})

      now = DateTime.utc_now()
      # Two events that predate the retention window.
      EventLog.record(event_fixture(at: DateTime.add(now, -10, :second)))
      EventLog.record(event_fixture(at: DateTime.add(now, -5, :second)))
      # One event that's within the window. Its insert triggers eviction.
      EventLog.record(event_fixture(at: now))
      wait_for_processing()

      # Only the within-window event survives.
      assert table_size() == 1
    end

    test "keeps events that are within the retention window" do
      start_supervised!({EventLog, retention_ms: 60_000})

      now = DateTime.utc_now()
      EventLog.record(event_fixture(at: DateTime.add(now, -30, :second)))
      EventLog.record(event_fixture(at: DateTime.add(now, -20, :second)))
      EventLog.record(event_fixture(at: now))
      wait_for_processing()

      assert table_size() == 3
    end
  end

  describe "max_events safety cap" do
    test "drops the oldest events when the cap is exceeded" do
      start_supervised!({EventLog, max_events: 3, retention_ms: 60 * 60 * 1000})

      now = DateTime.utc_now()

      for i <- 1..5 do
        EventLog.record(
          event_fixture(
            payload: %{n: i},
            at: DateTime.add(now, i, :second)
          )
        )
      end

      wait_for_processing()

      # Cap is 3 → the three newest survive.
      ns = Enum.map(EventLog.list(), & &1.payload.n)
      assert ns == [5, 4, 3]
    end

    test "doesn't evict anything when below the cap" do
      start_supervised!({EventLog, max_events: 10, retention_ms: 60 * 60 * 1000})

      for _ <- 1..3, do: EventLog.record(event_fixture(payload: %{}))
      wait_for_processing()

      assert table_size() == 3
    end
  end

  describe "filters" do
    setup do
      start_supervised!(EventLog)
      now = DateTime.utc_now()

      EventLog.record(event_fixture(type: :server_connected, at: DateTime.add(now, -30, :second)))

      EventLog.record(
        event_fixture(type: :health_transition, at: DateTime.add(now, -20, :second))
      )

      EventLog.record(event_fixture(type: :server_connected, at: DateTime.add(now, -10, :second)))
      wait_for_processing()

      %{now: now}
    end

    test "type filter (atom)" do
      assert [_, _] = EventLog.list(type: :server_connected)
      assert [_] = EventLog.list(type: :health_transition)
    end

    test "type filter (string — controller params pass-through)" do
      assert [_, _] = EventLog.list(%{"type" => "server_connected"})
    end

    test "unknown type returns empty" do
      assert [] = EventLog.list(type: :nonexistent)
    end

    test "before filter drops events at or after the cutoff", %{now: now} do
      cutoff = DateTime.to_iso8601(DateTime.add(now, -15, :second))
      assert [_, _] = EventLog.list(before: cutoff)
    end

    test "malformed before is ignored" do
      assert length(EventLog.list(before: "not-a-timestamp")) == 3
    end

    test "limit caps the result count" do
      assert length(EventLog.list(limit: 2)) == 2
    end

    test "limit accepts strings" do
      assert length(EventLog.list(%{"limit" => "1"})) == 1
    end

    test "unparseable limit falls back to the default" do
      assert length(EventLog.list(limit: "nope")) == 3
    end

    test "non-integer, non-binary limit falls back to the default" do
      assert length(EventLog.list(limit: :weird)) == 3
    end
  end
end
