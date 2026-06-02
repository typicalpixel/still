defmodule Still.MetricsCollector do
  @moduledoc """
  Controller-side cache of live per-server sample data reported by
  agents — CPU, memory, and disk utilization. Holds the most recent
  sample plus a short history buffer per server, keyed in ETS for
  concurrent reads.

  Best-effort, not durable. If this process crashes (or the controller
  restarts) history is gone and agents repopulate it on the next
  sample tick. Operators who need retained, queryable metrics should
  point Prometheus at Caddy's `/metrics` directly — this table exists
  so the dashboard feels alive, not to replace real observability.

  Writes are serialized through the GenServer. Reads go straight to
  ETS.
  """

  use GenServer

  @table :node_metrics
  @default_history 180

  @doc """
  Starts the collector. Options:

    * `:history_size` — number of samples to keep per server (default 180,
      which at the default 10s agent interval covers ~30 minutes).
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a sample for a server. Called via `GenServer.cast` from the
  agent's `NodeMetrics` process over Erlang distribution.

  The sample is expected to be a map with at least `:server_id` and
  `:at`; additional keys (`:cpu_pct`, `:mem_pct`, `:disk_pct`) ride
  through to the reader unchanged.
  """
  def record(sample) when is_map(sample) do
    GenServer.cast(__MODULE__, {:record, sample})
  end

  @doc """
  Returns the latest sample for the given server, or `nil` if none
  has been recorded yet. Reads directly from ETS — no GenServer hop.
  """
  def latest_for(server_id) when is_binary(server_id) do
    case :ets.lookup(@table, server_id) do
      [{^server_id, %{latest: latest}}] -> latest
      _ -> nil
    end
  end

  @doc """
  Returns the history ring buffer for the given server as a list,
  oldest first. Empty list when no samples have been recorded.
  """
  def history_for(server_id) when is_binary(server_id) do
    case :ets.lookup(@table, server_id) do
      [{^server_id, %{history: history}}] -> history
      _ -> []
    end
  end

  @impl true
  def init(opts) when is_list(opts) do
    table = :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    history_size = Keyword.get(opts, :history_size, @default_history)
    {:ok, %{table: table, history_size: history_size}}
  end

  @impl true
  def handle_cast({:record, %{server_id: server_id} = sample}, state)
      when is_binary(server_id) do
    existing =
      case :ets.lookup(@table, server_id) do
        [{^server_id, entry}] -> entry
        _ -> %{latest: nil, history: []}
      end

    history =
      (existing.history ++ [sample])
      |> Enum.take(-state.history_size)

    :ets.insert(@table, {server_id, %{latest: sample, history: history}})
    Still.Events.node_metrics(sample)

    {:noreply, state}
  end
end
