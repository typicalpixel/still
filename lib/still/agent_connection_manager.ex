defmodule Still.AgentConnectionManager do
  @moduledoc """
  Tracks the runtime state of all connected agents in an ETS table.

  The ETS table is the controller's view of "what is actually running
  across the fleet." It is a **cache**, not a source of truth — agents own
  their actual state and re-announce it on every connect/reconnect. If
  this process crashes, the supervisor restarts it with an empty table and
  agents refill it within seconds.

  Writes go through the GenServer (serialized). Reads go directly to the
  named ETS table (concurrent, no bottleneck).
  """

  use GenServer

  require Logger

  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Fleet

  @table :agent_state

  @doc """
  Starts the AgentConnectionManager and creates the ETS table.
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records an agent connection with the agent's full reported state.
  Called when an agent sends `{:agent_connected, report}`.
  """
  def agent_connected(report) when is_map(report) do
    GenServer.cast(__MODULE__, {:agent_connected, report})
  end

  @doc """
  Records an agent disconnection. Called when the controller detects
  a `:nodedown` for a known agent node.
  """
  def agent_disconnected(server_id) when is_binary(server_id) do
    GenServer.cast(__MODULE__, {:agent_disconnected, server_id})
  end

  @doc """
  Updates the reported state for a specific application on a specific agent.
  Called when an agent sends a health transition or deploy progress update.
  """
  def update_application_state(server_id, application_name, app_state)
      when is_binary(server_id) and is_binary(application_name) and is_map(app_state) do
    GenServer.cast(__MODULE__, {:update_app_state, server_id, application_name, app_state})
  end

  @doc """
  Returns the full agent report for the given server, or `nil` if not connected.
  Reads directly from ETS (no GenServer round-trip).
  """
  def get_agent_state(server_id) when is_binary(server_id) do
    case :ets.lookup(@table, server_id) do
      [{^server_id, report}] -> report
      [] -> nil
    end
  end

  @doc """
  Returns a list of all connected agent reports.
  """
  def list_agents do
    :ets.tab2list(@table)
    |> Enum.map(fn {_server_id, report} -> report end)
  end

  @doc """
  Returns true if the given server has an agent currently connected.
  Returns false when the manager (and its ETS table) isn't running —
  callers on cold paths (tests, startup) don't have to check first.
  """
  def connected?(server_id) when is_binary(server_id) do
    case :ets.whereis(@table) do
      :undefined -> false
      _ref -> :ets.member(@table, server_id)
    end
  end

  @impl true
  def init(_opts) do
    # six:ignore:next
    :net_kernel.monitor_nodes(true)
    table = :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:agent_connected, report}, state) when is_map(state) do
    server_id = report.server_id

    Logger.info("agent connected: #{server_id}")
    :ets.insert(@table, {server_id, report})
    persist_announcement(report)
    Still.Events.server_connected(server_id, report.node)
    audit_agent_event(server_id, :agent_connected, %{node: to_string(report.node)})

    {:noreply, state}
  end

  def handle_cast({:agent_disconnected, server_id}, state) when is_map(state) do
    Logger.info("agent disconnected: #{server_id}")
    :ets.delete(@table, server_id)
    Still.Events.server_disconnected(server_id)
    audit_agent_event(server_id, :agent_disconnected, %{})

    {:noreply, state}
  end

  def handle_cast({:update_app_state, server_id, app_name, app_state}, state)
      when is_map(state) do
    case :ets.lookup(@table, server_id) do
      [{^server_id, report}] ->
        updated = merge_application_state(report, app_name, app_state)
        :ets.insert(@table, {server_id, updated})

      [] ->
        Logger.warning("received app state update for unknown agent #{server_id}, ignoring")
    end

    {:noreply, state}
  end

  def handle_cast({:health_transition, server_id, transition}, state) when is_map(state) do
    case :ets.lookup(@table, server_id) do
      [{^server_id, report}] ->
        updated = merge_health_transition(report, transition)
        :ets.insert(@table, {server_id, updated})
        Still.Events.health_transition(transition.application, transition)

        audit_agent_event(
          server_id,
          :health_transition,
          %{
            application: transition.application,
            from: transition[:from],
            to: transition[:to]
          }
        )

      [] ->
        Logger.warning("received health transition for unknown agent #{server_id}, ignoring")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node}, state) when is_map(state) do
    case server_id_for_node(node) do
      nil ->
        :ok

      server_id ->
        Logger.info("agent disconnected: #{server_id} (node #{inspect(node)} down)")
        :ets.delete(@table, server_id)
        Still.Events.server_disconnected(server_id)
    end

    {:noreply, state}
  end

  def handle_info({:nodeup, _node}, state) when is_map(state), do: {:noreply, state}

  defp persist_announcement(report) do
    metadata = Map.get(report, :system_info) || %{}
    Still.Fleet.record_agent_announcement(report.server_id, metadata, report.connected_at)
  end

  # Records an audit row keyed to the agent (the server's actor identity).
  # Looks up the server name once for a readable label; if the server row
  # is gone (operator deleted it but a stray report is still in flight)
  # we silently skip — matches the "ignore unknown agent" pattern above.
  defp audit_agent_event(server_id, type, payload) do
    case Fleet.get_server(server_id) do
      nil ->
        :ok

      server ->
        {:ok, _} =
          Audit.record(Actor.agent(server),
            type: type,
            subject_type: :server,
            subject_id: server_id,
            payload: payload
          )

        :ok
    end
  end

  defp server_id_for_node(node) do
    :ets.foldl(
      fn
        {server_id, %{node: entry_node}}, nil when entry_node == node -> server_id
        _, acc -> acc
      end,
      nil,
      @table
    )
  end

  defp merge_application_state(report, app_name, app_state) do
    case Enum.find_index(report.applications, &(&1.application_name == app_name)) do
      nil ->
        new_entry = Map.merge(%{application_name: app_name}, app_state)
        %{report | applications: report.applications ++ [new_entry]}

      index ->
        updated =
          List.update_at(report.applications, index, fn app ->
            Map.merge(app, app_state)
          end)

        %{report | applications: updated}
    end
  end

  defp merge_health_transition(report, transition) do
    case Enum.find_index(report.applications, &(&1.application_name == transition.application)) do
      nil ->
        report

      index ->
        updated =
          List.update_at(report.applications, index, fn app ->
            Map.put(app, :health, transition.to)
          end)

        %{report | applications: updated}
    end
  end
end
