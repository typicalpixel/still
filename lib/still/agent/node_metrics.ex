defmodule Still.Agent.NodeMetrics do
  @moduledoc """
  Agent-side sampler. Collects CPU, memory, and disk utilization from
  `:os_mon` on a timer and casts each sample to the controller's
  `Still.MetricsCollector` over Erlang distribution.

  Runs on every server (including standalone, where the controller is
  the same node). The controller holds the ring buffer; this process
  is stateless aside from its timer reference and the ids it reports
  under.
  """

  use GenServer

  @default_interval_ms 10_000

  @doc """
  Starts the sampler. Required option: `:controller_node`. Optional:
  `:interval_ms` (default 10_000), `:server_id` (defaults to the
  `:still` application env).
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns a single sample map with the current CPU, memory, and disk
  utilization. Pure-ish — calls `:os_mon` probes, so it has side
  effects at the port layer, but no GenServer state or controller
  interaction. Exposed for direct testing without a running timer.
  """
  def build_sample(server_id) when is_binary(server_id) do
    %{
      server_id: server_id,
      at: DateTime.utc_now(),
      cpu_pct: cpu_pct(),
      mem_pct: mem_pct(),
      disk_pct: disk_pct(Application.get_env(:still, :applications_dir))
    }
  end

  @doc """
  Returns a used-memory percentage (0..100) from a
  `:memsup.get_system_memory_data/0` keyword list, or `nil` if the
  required keys are missing or total is zero.

  Prefers `:available_memory` (Linux `MemAvailable`, which excludes
  reclaimable page cache and buffers) over `:free_memory`, falling back
  to the latter when the kernel does not report it. This matches how
  external monitoring reports memory usage.
  """
  def mem_pct_from(data) when is_list(data) do
    with total when is_integer(total) and total > 0 <- Keyword.get(data, :system_total_memory),
         avail when is_integer(avail) and avail >= 0 <-
           Keyword.get(data, :available_memory, Keyword.get(data, :free_memory)) do
      used = total - avail
      round(used * 100 / total)
    else
      _ -> nil
    end
  end

  def mem_pct_from(_), do: nil

  @doc """
  Returns the used-disk percentage for the filesystem hosting `path`
  by longest-prefix match against a `:disksup.get_disk_data/0` list.
  `nil` when no mount matches.
  """
  def disk_pct_from(entries, path) when is_list(entries) and is_binary(path) do
    best =
      entries
      |> Enum.filter(fn {mount, _, _} -> String.starts_with?(path, to_string(mount)) end)
      |> Enum.max_by(fn {mount, _, _} -> String.length(to_string(mount)) end, fn -> nil end)

    case best do
      {_mount, _total, pct} when is_integer(pct) -> pct
      _ -> nil
    end
  end

  def disk_pct_from(_, _), do: nil

  @impl true
  def init(opts) when is_list(opts) do
    controller = Keyword.fetch!(opts, :controller_node)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    server_id = Keyword.get(opts, :server_id) || Application.get_env(:still, :server_id)

    state = %{controller: controller, interval: interval, server_id: server_id}

    if server_id do
      schedule_tick(interval)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, %{server_id: nil} = state), do: {:noreply, state}

  def handle_info(:tick, state) when is_map(state) do
    sample = build_sample(state.server_id)

    GenServer.cast({Still.MetricsCollector, state.controller}, {:record, sample})

    schedule_tick(state.interval)
    {:noreply, state}
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  # six:ignore:start
  # Thin :os_mon shellouts — integration-covered by the
  # node_metrics integration test.
  defp cpu_pct do
    case :cpu_sup.util() do
      pct when is_float(pct) -> round(pct)
      pct when is_integer(pct) -> pct
      _ -> nil
    end
  end

  defp mem_pct, do: mem_pct_from(:memsup.get_system_memory_data())

  defp disk_pct(nil), do: nil
  defp disk_pct(path) when is_binary(path), do: disk_pct_from(:disksup.get_disk_data(), path)

  # six:ignore:stop
end
