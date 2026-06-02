defmodule Still.EventLog do
  @moduledoc """
  An in-memory log of fleet-wide events — deployment transitions, health
  transitions, server connect / disconnect. Powers the dashboard's recent
  activity stream.

  Best-effort and transient. Crashes or controller restarts clear the
  log; new events repopulate it. Operators who need durable audit
  logging ship `Logger` output to their SIEM — this table is not the
  audit log.

  Retention is **time-based**: events stay for `retention_ms` (default
  24h), and every new write evicts anything older. A `max_events` count
  cap acts as a safety valve so a pathological burst can't blow memory
  — in normal operation it never fires. At ~1 KB per event × 50k cap,
  the upper bound is ~50 MB, well inside the budget for a 1 GB VPS.

  Writes flow via the `events:source` PubSub topic. `Still.Events`
  broadcast helpers publish there; this process subscribes, records the
  event in ETS, and rebroadcasts on `events:lobby` so connected clients
  see it in real time. Reads go directly to ETS through `list/1`.
  """

  use GenServer

  @table :event_log
  @pubsub Still.PubSub
  @source_topic "events:source"
  @client_topic "events:lobby"
  @default_retention_ms 24 * 60 * 60 * 1000
  @default_max_events 50_000
  @default_limit 50
  @max_limit 500

  @doc """
  Starts the event log. Options:

    * `:retention_ms` — how long events are retained (default 24h).
    * `:max_events` — hard cap on in-memory events (default 50_000).
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lists events, newest first. Accepts a map of filters (controller
  params pass-through) or a keyword list.

    * `type` — filter to a single type (string or atom).
    * `before` — ISO-8601 timestamp; return events strictly older.
    * `limit` — 1..500, default 50.
  """
  def list(filters \\ %{})

  def list(filters) when is_map(filters) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, event} -> event end)
    |> Enum.sort_by(& &1.at_us, :desc)
    |> apply_type_filter(fetch_filter(filters, :type))
    |> apply_before_filter(fetch_filter(filters, :before))
    |> Enum.take(clamp_limit(fetch_filter(filters, :limit, @default_limit)))
  end

  def list(filters) when is_list(filters), do: list(Map.new(filters))

  @doc """
  Publishes a fully-formed event onto the source topic. Used by tests
  that want to seed the log without going through `Still.Events`.
  """
  def record(%{type: _, payload: _, at: %DateTime{}} = event) do
    Phoenix.PubSub.broadcast(@pubsub, @source_topic, {:event_recorded, event})
  end

  @impl true
  def init(opts) when is_list(opts) do
    :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    Phoenix.PubSub.subscribe(@pubsub, @source_topic)

    {:ok,
     %{
       retention_ms: Keyword.get(opts, :retention_ms, @default_retention_ms),
       max_events: Keyword.get(opts, :max_events, @default_max_events),
       order: 0
     }}
  end

  @impl true
  def handle_info({:event_recorded, event}, state) when is_map(state) do
    order = state.order + 1
    id = event[:id] || event_id(order)
    at_us = event[:at_us] || datetime_to_us(event.at)

    event =
      event
      |> Map.put(:id, id)
      |> Map.put(:at_us, at_us)

    :ets.insert(@table, {id, event})
    evict_expired(state.retention_ms)
    evict_oldest_past_cap(state.max_events)

    Phoenix.PubSub.broadcast(@pubsub, @client_topic, {:event_recorded, event})

    {:noreply, %{state | order: order}}
  end

  defp evict_expired(retention_ms) do
    cutoff_us = System.os_time(:microsecond) - retention_ms * 1000

    match_spec = [
      {{:_, %{at_us: :"$1"}}, [{:<, :"$1", {:const, cutoff_us}}], [true]}
    ]

    :ets.select_delete(@table, match_spec)
  end

  # The cap is a safety valve for pathological bursts. `:ets.info(t, :size)`
  # is cheap; only when we're actually over do we pay for sorting.
  defp evict_oldest_past_cap(max_events) do
    case :ets.info(@table, :size) - max_events do
      excess when excess > 0 ->
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_id, event} -> event.at_us end)
        |> Enum.take(excess)
        |> Enum.each(fn {id, _event} -> :ets.delete(@table, id) end)

      _ ->
        :ok
    end
  end

  defp datetime_to_us(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)

  defp event_id(n) do
    "evt_#{System.system_time(:microsecond)}_#{n}"
  end

  defp apply_type_filter(events, nil), do: events

  defp apply_type_filter(events, type) when is_atom(type) do
    Enum.filter(events, &(&1.type == type))
  end

  defp apply_type_filter(events, type) when is_binary(type) do
    Enum.filter(events, &(to_string(&1.type) == type))
  end

  defp apply_before_filter(events, nil), do: events

  defp apply_before_filter(events, iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, cutoff, _} -> Enum.filter(events, &(DateTime.compare(&1.at, cutoff) == :lt))
      _ -> events
    end
  end

  defp fetch_filter(map, key, default \\ nil) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp clamp_limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp clamp_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> clamp_limit(int)
      _ -> @default_limit
    end
  end

  defp clamp_limit(_), do: @default_limit
end
