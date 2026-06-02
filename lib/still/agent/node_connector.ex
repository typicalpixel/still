defmodule Still.Agent.NodeConnector do
  @moduledoc """
  Owns the agent's view of the controller: the Erlang distribution link,
  the initial state announcement, and per-application state updates.

  On start the agent tries to connect to the controller node, retrying on
  a fixed interval if the link is down. Once connected (or in standalone
  mode, where the controller is this same node), it announces the full
  contents of every `state.json` under the applications directory so the
  controller's ETS table reflects what is actually running before any
  new deploy happens. After that, every successful deploy or rollback
  sends an incremental update for the affected application via
  `report_application_state/2`.

  The actual `Node.connect/1` call is injectable via the `:connector`
  option so tests can stub it without going through real Erlang
  distribution.
  """

  use GenServer

  require Logger

  alias Still.Agent.ApplicationState
  alias Still.Agent.StatePersistence
  alias Still.Agent.Systemd
  alias Still.Agent.SystemInfo

  @default_reconnect_interval_ms 5_000

  @doc """
  Starts the NodeConnector and registers it under the module name.

  Required option: `:controller_node` (an atom node name like
  `:"still_controller@10.0.0.1"`). In standalone mode, pass `Node.self()`
  — the module detects that case and skips the remote-connect dance,
  announcing directly to the local `AgentConnectionManager`.

  Optional: `:reconnect_interval_ms` (default 5000), `:connector`
  (default `&Node.connect/1`).
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the current connection status (`:connected` or `:disconnected`).
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Returns the configured controller node name.
  """
  def controller_node do
    GenServer.call(__MODULE__, :controller_node)
  end

  @doc """
  Pushes an incremental application-state update to the controller's
  `AgentConnectionManager`. Called by `DeploymentManager` after a
  successful deploy or rollback so the controller's ETS view of
  "what's running" converges without waiting for the next reconnect.

  No-op when `server_id` is not configured — the update has nowhere to
  go until the agent has an identity.
  """
  def report_application_state(application_name, %ApplicationState{} = state)
      when is_binary(application_name) do
    GenServer.cast(__MODULE__, {:report_application_state, application_name, state})
  end

  @doc """
  Forwards a health transition from the local HealthMonitor to the
  controller's AgentConnectionManager. Called by the HealthMonitor's
  reporter function when an application transitions between `:healthy`,
  `:unhealthy`, or `:unknown`.
  """
  def report_health_transition(transition) when is_map(transition) do
    GenServer.cast(__MODULE__, {:report_health_transition, transition})
  end

  @impl true
  def init(opts) when is_list(opts) do
    controller = Keyword.fetch!(opts, :controller_node)
    interval = Keyword.get(opts, :reconnect_interval_ms, @default_reconnect_interval_ms)
    connector = Keyword.get(opts, :connector, &Node.connect/1)
    server_id = Application.get_env(:still, :server_id)

    # six:ignore:next
    :net_kernel.monitor_nodes(true)

    send(self(), :try_connect)

    {:ok,
     %{
       controller: controller,
       status: :disconnected,
       interval: interval,
       connector: connector,
       server_id: server_id
     }}
  end

  @impl true
  def handle_call(:status, _from, state) when is_map(state) do
    {:reply, state.status, state}
  end

  def handle_call(:controller_node, _from, state) when is_map(state) do
    {:reply, state.controller, state}
  end

  @impl true
  def handle_cast({:report_application_state, _app, _s}, %{server_id: nil} = state) do
    {:noreply, state}
  end

  def handle_cast(
        {:report_application_state, application_name, %ApplicationState{} = app_state},
        %{} = state
      ) do
    payload = state_to_report(application_name, app_state)

    GenServer.cast(
      {Still.AgentConnectionManager, state.controller},
      {:update_app_state, state.server_id, application_name, payload}
    )

    {:noreply, state}
  end

  def handle_cast({:report_health_transition, _transition}, %{server_id: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:report_health_transition, transition}, %{} = state) do
    GenServer.cast(
      {Still.AgentConnectionManager, state.controller},
      {:health_transition, state.server_id, transition}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:try_connect, %{controller: controller} = state) when controller == node() do
    # Standalone mode: the controller IS this node. Skip the connect dance
    # and announce directly to the local AgentConnectionManager.
    announce(state)
    {:noreply, %{state | status: :connected}}
  end

  def handle_info(:try_connect, state) when is_map(state) do
    if state.connector.(state.controller) do
      announce(state)
      {:noreply, %{state | status: :connected}}
    else
      Logger.warning("failed to connect to controller #{inspect(state.controller)}")
      schedule_reconnect(state.interval)
      {:noreply, %{state | status: :disconnected}}
    end
  end

  def handle_info({:nodeup, node}, %{controller: controller} = state) when node == controller do
    announce(state)
    {:noreply, %{state | status: :connected}}
  end

  def handle_info({:nodedown, node}, %{controller: controller} = state) when node == controller do
    Logger.warning("controller #{inspect(node)} disconnected")
    schedule_reconnect(state.interval)
    {:noreply, %{state | status: :disconnected}}
  end

  def handle_info({:nodeup, _other}, state) when is_map(state), do: {:noreply, state}
  def handle_info({:nodedown, _other}, state) when is_map(state), do: {:noreply, state}

  defp schedule_reconnect(interval) do
    Process.send_after(self(), :try_connect, interval)
  end

  # Announce this agent to the controller's AgentConnectionManager so the
  # orchestrator knows this server is reachable. No-op if server_id is not
  # configured — the agent still holds the Erlang distribution link but is
  # invisible to the controller until registration happens some other way.
  defp announce(%{server_id: nil}), do: :ok

  defp announce(%{controller: controller, server_id: server_id}) do
    report = build_report(server_id)
    GenServer.cast({Still.AgentConnectionManager, controller}, {:agent_connected, report})
  end

  @doc """
  Builds the announcement payload this agent sends to the controller on
  connect/reconnect. Reads every `state.json` on disk so the controller's
  view of "what is actually running" starts correct from the first
  message — not just an empty shell that has to be filled in later via
  per-deploy updates.

  Exposed so it can be unit-tested without real Erlang distribution.
  """
  def build_report(server_id) when is_binary(server_id) do
    %{
      server_id: server_id,
      node: Node.self(),
      connected_at: DateTime.utc_now(),
      system_info: SystemInfo.collect(),
      applications: current_applications()
    }
  end

  defp current_applications do
    Enum.flat_map(StatePersistence.list_applications(), fn application_name ->
      case StatePersistence.read(application_name) do
        {:ok, %ApplicationState{} = state} -> [state_to_report(application_name, state)]
        {:error, _} -> []
      end
    end)
  end

  defp state_to_report(application_name, %ApplicationState{} = state) do
    runtime = Systemd.info_for(application_name, state.active_slot)

    %{
      application_name: application_name,
      type: state.type,
      active_slot: state.active_slot,
      active_port: state.active_port,
      current_version: state.current_version,
      previous_version: state.previous_version,
      last_health_check_at: state.last_health_check_at,
      pid: runtime.pid,
      active_state: runtime.active_state,
      active_enter_at: runtime.active_enter_at
    }
  end
end
