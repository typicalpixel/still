defmodule Still.Application do
  @moduledoc false

  use Application

  alias Still.Agent.NodeConnector

  @impl true
  def start(_type, _args) do
    mode = Application.get_env(:still, :mode, :standalone)
    children = common_children() ++ children_for_mode(mode)

    opts = [strategy: :one_for_one, name: Still.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    StillWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @doc """
  Returns the child specs for the given runtime mode. Used by `start/2` to
  branch the supervision tree.

  Controller-side workers (AgentConnectionManager, Orchestrator,
  ReconciliationLoop, IngressReconciler, self-announce NodeConnector, etc.)
  are gated behind `:start_controller_workers`. The test env sets it to
  `false` so tests can start each process manually with custom options
  (stub agent callers, test-pid notifiers, etc.). Production and dev
  default to starting them automatically.
  """
  def children_for_mode(:controller) do
    base = controller_base_children()

    if start_controller_workers?() do
      base ++
        controller_worker_children() ++
        controller_only_children() ++
        controller_self_announce_children()
    else
      base
    end
  end

  def children_for_mode(:agent) do
    controller = Application.fetch_env!(:still, :controller_node)

    [
      {Still.Agent.NodeConnector, controller_node: controller},
      {Still.Agent.NodeMetrics, controller_node: controller},
      {Still.Agent.DeployLogCollector, controller_node: controller},
      {Still.Agent.DeploymentManager, []},
      {Still.Agent.HealthMonitor, reporter: &NodeConnector.report_health_transition/1}
    ]
  end

  def children_for_mode(:standalone) do
    # Controller + agent children, minus NodeConnector (the controller is local)
    # and minus IngressReconciler — the agent-local routes already front the
    # app, so a controller-side ingress layer would just loop back to the same
    # Caddy and create route collisions.
    base = controller_base_children()
    workers = if start_controller_workers?(), do: controller_worker_children(), else: []
    base ++ workers ++ standalone_agent_children()
  end

  defp start_controller_workers? do
    Application.get_env(:still, :start_controller_workers, true)
  end

  defp common_children do
    [
      StillWeb.Telemetry,
      # Supervises the Orchestrator's fire-and-forget deploy/route tasks so a
      # crashing task can't take the coordinator (or sibling deploys) down.
      {Task.Supervisor, name: Still.Orchestrator.TaskSupervisor}
    ]
  end

  defp controller_base_children do
    [
      Still.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:still, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:still, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Still.PubSub},
      # Backs the login throttle (StillWeb.Plugs.LoginRateLimit).
      Still.RateLimiter,
      # Start to serve requests, typically the last entry
      StillWeb.Endpoint
    ]
  end

  defp controller_worker_children do
    [
      Still.AgentConnectionManager,
      Still.MetricsCollector,
      Still.DeployLogCollector,
      Still.CaddyMetricsScraper,
      Still.EventLog,
      Still.Orchestrator,
      Still.ReconciliationLoop
    ]
  end

  # Controller-only children: the IngressReconciler keeps the controller
  # Caddy pointed at remote agent hosts. Standalone doesn't run this
  # because agents on the same box already front themselves.
  defp controller_only_children do
    [Still.IngressReconciler]
  end

  # Standalone mode also runs NodeConnector, but configured with the local
  # node as the "controller" — skips the Erlang distribution dance and
  # announces directly to the local AgentConnectionManager so /api/status
  # reflects the running state from the very first boot.
  defp standalone_agent_children do
    [
      {Still.Agent.NodeConnector, controller_node: Node.self()},
      {Still.Agent.NodeMetrics, controller_node: Node.self()},
      {Still.Agent.DeployLogCollector, controller_node: Node.self()},
      {Still.Agent.DeploymentManager, []},
      {Still.Agent.HealthMonitor, reporter: &NodeConnector.report_health_transition/1}
    ]
  end

  # Pure controller mode self-announces so its own server row shows up as
  # connected in /api/servers (otherwise no one ever tells ACM the
  # controller is alive). Deliberately excludes DeploymentManager and
  # HealthMonitor — controllers don't run user applications; those
  # concerns belong to boxes with the "application" role.
  defp controller_self_announce_children do
    [
      {Still.Agent.NodeConnector, controller_node: Node.self()},
      {Still.Agent.NodeMetrics, controller_node: Node.self()}
    ]
  end

  # By default, sqlite migrations are run when using a release
  defp skip_migrations? do
    System.get_env("RELEASE_NAME") == nil
  end
end
