defmodule Still.DeployLogCollector do
  @moduledoc """
  Controller-side cache of in-flight deploy logs. Agents capture their unit's
  journal over the deploy window (`Still.Agent.DeployLogCollector`) and cast the
  current blob here on a tick; the final cast persists it onto the deployment
  step. The dashboard reads the live buffer here while a deploy runs and the
  stored `deployment_step.log` once it lands.

  Buffers live in ETS keyed by `{deployment_id, server_id}`, mirroring
  `Still.MetricsCollector`. Best-effort and non-durable — a controller restart
  drops in-flight buffers, but any finalized step already has its log in the
  database.
  """

  use GenServer

  require Logger

  alias Still.Deployments
  alias Still.Events

  @table :deploy_logs
  @sweep_interval_ms 60_000
  @terminal_statuses [:completed, :failed, :rolled_back]

  @doc "Starts the collector and creates the ETS buffer table."
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records the current captured log for a step. `done?` true means this is the
  agent's final blob: it's persisted onto the step and the live buffer is
  dropped. Called via `GenServer.cast` from the agent over distribution.
  """
  def capture(deployment_id, server_id, log, done?)
      when is_binary(deployment_id) and is_binary(server_id) and is_binary(log) and
             is_boolean(done?) do
    GenServer.cast(__MODULE__, {:capture, deployment_id, server_id, log, done?})
  end

  @doc """
  Returns the live captured log for a step, or `nil` when none is buffered —
  either the deploy hasn't reported yet or it finalized and the log now lives
  on the step. Reads straight from ETS.
  """
  def text_for(deployment_id, server_id)
      when is_binary(deployment_id) and is_binary(server_id) do
    # The table only exists while the collector runs; a reader (the dashboard)
    # may hit this before it starts or after a crash — treat a missing table as
    # "nothing buffered" rather than raising.
    case :ets.whereis(@table) do
      :undefined ->
        nil

      _tid ->
        case :ets.lookup(@table, {deployment_id, server_id}) do
          [{_key, log}] -> log
          _ -> nil
        end
    end
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:capture, deployment_id, server_id, log, done?}, state) when is_map(state) do
    key = {deployment_id, server_id}

    if done? do
      persist(deployment_id, server_id, log)
      :ets.delete(@table, key)
    else
      :ets.insert(@table, {key, log})
    end

    Events.deploy_log_updated(deployment_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) when is_map(state) do
    sweep_orphans()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # Only a done?:true cast removes a buffer; an agent/node death or a partition
  # between begin and finish would otherwise leak the entry until the next
  # controller restart. Drop any buffer whose deployment has gone terminal (or
  # vanished) without finalizing.
  defp sweep_orphans do
    collect = fn {{deployment_id, _server_id} = key, _log}, acc ->
      [{key, deployment_id} | acc]
    end

    :ets.foldl(collect, [], @table)
    |> Enum.each(fn {key, deployment_id} ->
      if orphaned?(deployment_id), do: :ets.delete(@table, key)
    end)
  end

  defp orphaned?(deployment_id) do
    case Deployments.deployment_status(deployment_id) do
      nil -> true
      status -> status in @terminal_statuses
    end
  end

  # Best-effort: a transient DB fault (SQLite lock) must drop one log, not crash
  # the collector and wipe every other in-flight deploy's live buffer.
  defp persist(deployment_id, server_id, log) do
    case Deployments.put_step_log(deployment_id, server_id, log) do
      {:ok, _step} ->
        :ok

      :error ->
        Logger.debug("deploy_log: no step for #{deployment_id}/#{server_id}, dropping log")
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "deploy_log: persisting #{deployment_id}/#{server_id} failed: #{Exception.message(error)}"
      )

      :ok
  end
end
