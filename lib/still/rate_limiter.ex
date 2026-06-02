defmodule Still.RateLimiter do
  @moduledoc """
  Fixed-window, in-memory rate limiter. Every update serializes through this
  GenServer, so the window arithmetic is race-free without ETS. Intended for
  low-volume buckets (per-IP login attempts), not high-throughput paths.

  Buckets are pruned periodically so a flood of distinct keys can't grow the
  state without bound.
  """

  use GenServer

  @sweep_interval_ms 60_000
  # Buckets idle longer than this are dropped on the next sweep — generously
  # larger than any real window, so a bucket is only swept well after it would
  # have reset on its own.
  @max_idle_ms 3_600_000

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records a hit for `key`. Returns `:ok` while fewer than `max` hits have
  happened in the current `window_ms`; otherwise `{:error, retry_after_seconds}`
  without counting the rejected hit.
  """
  def hit(server \\ __MODULE__, key, max, window_ms)
      when is_integer(max) and is_integer(window_ms) do
    GenServer.call(server, {:hit, key, max, window_ms})
  end

  @doc "Drops all buckets. Test helper."
  def reset(server \\ __MODULE__) when is_atom(server) or is_pid(server) do
    GenServer.call(server, :reset)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:hit, key, max, window_ms}, _from, buckets) when is_map(buckets) do
    now = System.monotonic_time(:millisecond)
    {result, bucket} = decide(Map.get(buckets, key), now, max, window_ms)
    {:reply, result, Map.put(buckets, key, bucket)}
  end

  def handle_call(:reset, _from, _buckets), do: {:reply, :ok, %{}}

  @impl true
  def handle_info(:sweep, buckets) do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, prune(buckets, System.monotonic_time(:millisecond), @max_idle_ms)}
  end

  # Window decision for one bucket. A rejected hit is not counted, so a
  # throttled attacker can't push the window's start forward indefinitely.
  defp decide(bucket, now, max, window_ms) do
    case bucket do
      {count, start} when now - start < window_ms and count >= max ->
        {{:error, retry_after(start, window_ms, now)}, {count, start}}

      {count, start} when now - start < window_ms ->
        {:ok, {count + 1, start}}

      _expired_or_new ->
        {:ok, {1, now}}
    end
  end

  @doc """
  Drops buckets idle longer than `max_idle_ms`. Called by the periodic sweep;
  public so the keep and drop branches can be tested with a controlled clock
  (tests must not sleep).
  """
  def prune(buckets, now, max_idle_ms)
      when is_map(buckets) and is_integer(now) and is_integer(max_idle_ms) do
    Map.filter(buckets, fn {_key, {_count, start}} -> now - start < max_idle_ms end)
  end

  defp retry_after(start, window_ms, now), do: max(1, ceil((start + window_ms - now) / 1000))
end
