defmodule Still.CaddyMetricsScraper do
  @moduledoc """
  Controller-side GenServer that scrapes the local Caddy's `/metrics`
  endpoint on a timer, parses `caddy_http_requests_total` counters by
  host, and keeps a per-application rolling sample window for dashboard
  sparklines and 24h totals.

  Best-effort and in-memory — if this process crashes the window resets
  and subsequent samples repopulate it. Operators who need retained,
  queryable metrics point Prometheus at the same Caddy endpoint
  directly.

  Prometheus counters are monotonic within a Caddy process. On a
  counter reset (Caddy restart), the scraper detects `new < previous`
  and treats the new value as the baseline rather than emitting a
  negative delta sample.
  """

  use GenServer

  require Logger

  alias Still.Applications

  @table :caddy_metrics
  @default_interval_ms 60_000
  @default_history 1440

  @doc """
  Starts the scraper. Options:

    * `:interval_ms` — scrape cadence (default 60_000)
    * `:history_size` — samples kept per application (default 1440,
      i.e. 24h at the default interval)
    * `:http_getter` — arity-1 function taking a URL and returning
      `{:ok, body}` or `{:error, reason}`. Tests inject a stub; the
      default uses `Req`.
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the latest sample map for `application_name`, or `nil`."
  def latest_for(application_name) when is_binary(application_name) do
    case :ets.lookup(@table, application_name) do
      [{^application_name, %{history: [_ | _] = history}}] -> List.last(history)
      _ -> nil
    end
  end

  @doc "Returns the sample history for `application_name` — oldest first."
  def history_for(application_name) when is_binary(application_name) do
    case :ets.lookup(@table, application_name) do
      [{^application_name, %{history: history}}] -> history
      _ -> []
    end
  end

  @doc """
  Sum of deltas across all samples in the window for the given
  application — the "requests over the last N minutes" number the
  dashboard shows. Returns 0 when no samples have been recorded.
  """
  def window_total(application_name) when is_binary(application_name) do
    application_name
    |> history_for()
    |> Enum.reduce(0, fn %{delta: delta}, acc -> acc + delta end)
  end

  @doc """
  Synchronously fires one scrape. Exposed for tests — in production the
  timer drives ticks.
  """
  def scrape_now do
    GenServer.call(__MODULE__, :scrape_now)
  end

  @doc """
  Parses a Prometheus text-format payload, extracting
  `caddy_http_requests_total` counters summed per `host` label. Returns
  a map of `host_string => total_count`. Lines without a `host` label
  are ignored — per-host metrics require `per_host: true` on the Caddy
  server config.
  """
  def parse_host_totals(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, &accumulate_host_total/2)
  end

  # Each line is either a comment (# HELP / # TYPE), a labeled metric
  # sample, or something we don't care about. Match only the
  # caddy_http_requests_total samples with a host label.
  defp accumulate_host_total("#" <> _, acc), do: acc

  defp accumulate_host_total(line, acc) do
    case Regex.run(
           ~r/^caddy_http_requests_total\{([^}]*)\}\s+([0-9eE.+-]+)/,
           line
         ) do
      [_, labels, value_str] ->
        case {parse_host_label(labels), parse_numeric(value_str)} do
          {host, count} when is_binary(host) and is_number(count) ->
            Map.update(acc, host, count, &(&1 + count))

          _ ->
            acc
        end

      _ ->
        acc
    end
  end

  defp parse_host_label(labels) when is_binary(labels) do
    case Regex.run(~r/host="([^"]*)"/, labels) do
      [_, host] -> host
      _ -> nil
    end
  end

  defp parse_numeric(str) do
    case Float.parse(str) do
      {value, _} -> value
      :error -> nil
    end
  end

  @impl true
  def init(opts) when is_list(opts) do
    :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])

    state = %{
      interval: Keyword.get(opts, :interval_ms, @default_interval_ms),
      history_size: Keyword.get(opts, :history_size, @default_history),
      http_getter: Keyword.get(opts, :http_getter, &default_http_getter/1),
      last_counts: %{}
    }

    schedule_tick(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:scrape_now, _from, state) when is_map(state) do
    {:reply, :ok, do_scrape(state)}
  end

  @impl true
  def handle_info(:tick, state) when is_map(state) do
    new_state = do_scrape(state)
    schedule_tick(state.interval)
    {:noreply, new_state}
  end

  defp do_scrape(state) do
    case state.http_getter.(metrics_url()) do
      {:ok, body} ->
        host_totals = parse_host_totals(body)
        record(host_totals, state)

      {:error, reason} ->
        Logger.warning("Caddy metrics scrape failed: #{inspect(reason)}")
        state
    end
  end

  # For each application, find the matching host in host_totals, compute
  # the delta since last sample, append a new sample, and update the
  # last-counts map. Reset-safe: if the new counter is lower than the
  # stored one (Caddy restart) we treat the new value as the baseline
  # and emit a zero-delta sample.
  defp record(host_totals, state) do
    now = DateTime.utc_now()

    new_last_counts =
      Enum.reduce(Applications.list_applications(), state.last_counts, fn app, acc ->
        current = Map.get(host_totals, app.domain, 0)
        previous = Map.get(acc, app.domain)
        delta = compute_delta(previous, current)

        append_sample(app.name, %{at: now, delta: delta, total: current}, state.history_size)

        Map.put(acc, app.domain, current)
      end)

    %{state | last_counts: new_last_counts}
  end

  defp compute_delta(nil, _current), do: 0
  defp compute_delta(previous, current) when current < previous, do: 0
  defp compute_delta(previous, current), do: trunc(current - previous)

  defp append_sample(application_name, sample, history_size) do
    existing =
      case :ets.lookup(@table, application_name) do
        [{^application_name, entry}] -> entry
        _ -> %{history: []}
      end

    history = Enum.take(existing.history ++ [sample], -history_size)
    :ets.insert(@table, {application_name, %{history: history}})
    Still.Events.app_metrics(application_name, sample)
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp metrics_url do
    Application.fetch_env!(:still, :caddy_admin_url) <> "/metrics"
  end

  # six:ignore:start
  # Thin Req wrapper — covered by the per-host Prometheus output in the
  # existing Caddy bootstrap integration tests, not via a unit mock.
  defp default_http_getter(url) do
    case Req.get(url, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # six:ignore:stop
end
