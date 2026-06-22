defmodule Still.Agent.DeployLogCollector do
  @moduledoc """
  Agent-side capture of a deploy's journal. While a deploy runs, the
  `DeploymentManager` calls `begin/3` just before it starts the target slot and
  `finish/0` once the deploy is terminal. Between those, this process polls the
  slot's systemd journal on a tick and casts the current blob to the
  controller's `Still.DeployLogCollector`, so the dashboard can stream the boot
  live and the crash reason survives a failed deploy.

  Capture is bounded by the deploy window: it starts from the journal cursor
  taken at `begin/3` and stops at `finish/0` — it never tails a running app.
  One deploy at a time (the `DeploymentManager` serializes them), so the
  collector holds a single capture.
  """

  use GenServer

  require Logger

  alias Still.DeployLog

  @default_interval_ms 2_000

  # journalctl has no native timeout; we run it in a task we can shut down. The
  # call timeout sits above it so begin/finish degrade to last-good rather than
  # raising into the deploy when a journal read is slow.
  @journalctl_timeout_ms 10_000
  @call_timeout_ms 15_000

  @doc """
  Starts the collector. Required option: `:controller_node` (where captured
  logs are cast). Optional: `:interval_ms` (default 2000).
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Begins capturing the journal for `application@slot`, tagging casts with
  `deployment_id`. Records the journal cursor now so capture covers only the
  window from here on. No-op when `deployment_id` or the agent's `server_id`
  is missing — there is nothing to attribute the log to.
  """
  def begin(deployment_id, application, slot) when is_binary(application) do
    GenServer.call(__MODULE__, {:begin, deployment_id, application, slot}, @call_timeout_ms)
  end

  @doc """
  Ends the current capture: reads the journal one last time, casts the final
  blob (so the controller persists it), and stops the tick. Synchronous so the
  `DeploymentManager` captures the journal *before* it stops a failed slot —
  capture-then-stop. No-op when nothing is being captured.
  """
  def finish do
    GenServer.call(__MODULE__, :finish, @call_timeout_ms)
  end

  @impl true
  def init(opts) when is_list(opts) do
    {:ok,
     %{
       controller: Keyword.get(opts, :controller_node, node()),
       interval: Keyword.get(opts, :interval_ms, @default_interval_ms),
       capture: nil
     }}
  end

  @impl true
  def handle_call({:begin, deployment_id, application, slot}, _from, state) when is_map(state) do
    {:reply, :ok, maybe_start(cancel_capture(state), deployment_id, application, slot)}
  end

  def handle_call(:finish, _from, %{capture: nil} = state) do
    {:reply, :ok, state}
  end

  # six:ignore:start
  def handle_call(:finish, _from, state) when is_map(state),
    do: {:reply, :ok, finish_capture(state)}

  # six:ignore:stop

  @impl true
  def handle_info(:tick, %{capture: nil} = state), do: {:noreply, state}

  # six:ignore:next
  def handle_info(:tick, state), do: {:noreply, tick_capture(state)}

  # six:ignore:start
  # Everything below only runs once a capture is live, which requires the
  # journalctl shellout in start_capture/1 — exercised by the deploy-log
  # integration test against a real unit, not unit mocks.

  defp maybe_start(state, deployment_id, application, slot) do
    if deployment_id && Application.get_env(:still, :server_id) do
      start_capture(state, deployment_id, application, slot)
    else
      state
    end
  end

  defp cancel_capture(%{capture: nil} = state), do: state

  defp cancel_capture(%{capture: %{tref: tref}} = state) do
    if tref, do: Process.cancel_timer(tref)
    %{state | capture: nil}
  end

  defp finish_capture(state) do
    flush(state, state.capture, true)
    cancel_capture(state)
  end

  defp tick_capture(state) do
    capture = flush(state, state.capture, false)
    %{state | capture: %{capture | tref: schedule_tick(state.interval)}}
  end

  defp schedule_tick(interval), do: Process.send_after(self(), :tick, interval)

  defp start_capture(state, deployment_id, application, slot) do
    capture = %{
      deployment_id: deployment_id,
      server_id: Application.get_env(:still, :server_id),
      unit: "#{application}@#{slot}",
      cursor: capture_cursor(),
      since: since_boundary(),
      last: "",
      tref: schedule_tick(state.interval)
    }

    %{state | capture: capture}
  end

  # Read the journal, cast it, and return the capture with its last-good blob
  # updated. A failed read keeps the previous blob rather than blanking it; on
  # the final flush we also keep whichever blob is fuller, so a journal vacuum
  # mid-deploy can't shrink the persisted capture below an earlier tick.
  defp flush(state, capture, done?) do
    fresh = read_log(capture)
    log = if done?, do: DeployLog.fuller(fresh, capture.last), else: fresh

    if done? and not controller_reachable?(state.controller) do
      Logger.warning(
        "deploy_log: controller #{inspect(state.controller)} unreachable at finalize — the " <>
          "captured log for deployment #{capture.deployment_id} was not delivered; the crash " <>
          "reason is still in `journalctl -u #{capture.unit}` on this host"
      )
    end

    GenServer.cast(
      {Still.DeployLogCollector, state.controller},
      {:capture, capture.deployment_id, capture.server_id, log, done?}
    )

    %{capture | last: log}
  end

  defp read_log(capture) do
    DeployLog.resolve_read(read_window(capture), capture.last)
  end

  defp controller_reachable?(controller) do
    controller == node() or controller in Node.list()
  end

  # The global journal tip, captured at begin so the window starts here. nil
  # when journalctl can't report one — capture falls back to a time boundary
  # (see journal_args/3).
  defp capture_cursor do
    case run_journalctl(["-n", "0", "--show-cursor", "--no-pager"]) do
      {:ok, output} -> DeployLog.parse_cursor(output)
      :error -> nil
    end
  end

  # A UTC wall-clock boundary (with a small margin) for the cursor-less fallback,
  # so it reads only this deploy's window rather than the unit's whole history —
  # which on a redeploy could surface a PRIOR deploy's crash. The "UTC" suffix
  # makes journalctl interpret it regardless of the host timezone.
  defp since_boundary do
    DateTime.utc_now()
    |> DateTime.add(-2, :second)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  defp read_window(capture),
    do: run_journalctl(journal_args(capture.unit, capture.cursor, capture.since))

  # System.cmd has no native timeout. Run journalctl in a task we can shut down
  # so a slow or hung journal — the crash-loop / disk-pressure case this feature
  # targets — degrades to :error (and last-good) instead of blocking the deploy.
  defp run_journalctl(args) do
    task =
      Task.async(fn ->
        try do
          System.cmd("journalctl", args, stderr_to_stdout: false)
        rescue
          ErlangError -> :error
        end
      end)

    case Task.yield(task, @journalctl_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      _ -> :error
    end
  end

  defp journal_args(unit, nil, since) do
    ["-u", unit, "--since", since, "-o", "short-iso", "--no-pager", "-n", "2000"]
  end

  defp journal_args(unit, cursor, _since) do
    ["-u", unit, "--after-cursor", cursor, "-o", "short-iso", "--no-pager", "-n", "2000"]
  end

  # six:ignore:stop
end
