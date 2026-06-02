defmodule Still.ReconciliationLoop do
  @moduledoc """
  Periodically compares desired state (database) against actual state (agent
  reports in ETS) and flags drift.

  v0.1 detects drift and logs it. Auto-remediation (triggering re-deploys to
  fix drift) is deferred to v1.0+.
  """

  use GenServer

  require Logger

  alias Still.AgentConnectionManager
  alias Still.Applications

  @default_interval_ms 30_000

  @doc """
  Starts the ReconciliationLoop.

  Options:
    * `:interval_ms` — reconciliation interval (default 30s)
    * `:on_drift` — 1-arity fn called with the list of drifted entries
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs reconciliation immediately and returns the full result list.
  """
  def reconcile_now do
    GenServer.call(__MODULE__, :reconcile)
  end

  @impl true
  def init(opts) when is_list(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    on_drift = Keyword.get(opts, :on_drift, &default_on_drift/1)
    schedule(interval)
    {:ok, %{interval: interval, on_drift: on_drift}}
  end

  @impl true
  def handle_call(:reconcile, _from, state) when is_map(state) do
    results = do_reconcile()
    report_drift(results, state.on_drift)
    {:reply, results, state}
  end

  @impl true
  def handle_info(:reconcile, state) when is_map(state) do
    results = do_reconcile()
    report_drift(results, state.on_drift)
    schedule(state.interval)
    {:noreply, state}
  end

  @doc """
  Compares all application server assignments (desired state in DB) against
  agent reports (actual state in ETS). Returns a list of result maps.

  Each result has: `:application_name`, `:server_id`, `:desired_version`,
  `:actual_version`, and `:status` (one of `:in_sync`, `:drifted`,
  `:agent_disconnected`, `:not_deployed`).
  """
  def do_reconcile do
    Applications.list_all_assignments()
    |> Enum.map(&check_assignment/1)
  end

  defp check_assignment(%{desired_version: nil} = assignment) do
    Map.merge(assignment, %{actual_version: nil, status: :not_deployed})
  end

  defp check_assignment(assignment) do
    case AgentConnectionManager.get_agent_state(assignment.server_id) do
      nil ->
        Map.merge(assignment, %{actual_version: nil, status: :agent_disconnected})

      report ->
        actual = find_app_version(report.applications, assignment.application_name)
        status = if actual == assignment.desired_version, do: :in_sync, else: :drifted
        Map.merge(assignment, %{actual_version: actual, status: status})
    end
  end

  defp find_app_version(applications, name) do
    case Enum.find(applications, &(&1.application_name == name)) do
      nil -> nil
      app -> app.current_version
    end
  end

  defp report_drift(results, on_drift) do
    drifted = Enum.reject(results, &(&1.status in [:in_sync, :not_deployed]))

    if drifted != [] do
      on_drift.(drifted)
    end
  end

  defp schedule(interval) do
    Process.send_after(self(), :reconcile, interval)
  end

  defp default_on_drift(drifted) do
    Enum.each(drifted, fn entry ->
      Logger.warning(
        "drift: #{entry.application_name} on #{entry.server_id} — " <>
          "desired=#{entry.desired_version} actual=#{entry.actual_version} status=#{entry.status}"
      )
    end)
  end
end
