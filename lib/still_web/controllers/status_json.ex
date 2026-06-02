defmodule StillWeb.StatusJSON do
  @moduledoc """
  JSON serialization for the `/api/status/*` endpoints. Takes merged
  data from `Still.Status` and shapes it for the wire.
  """

  alias Still.Fleet.Server
  alias StillWeb.APIVersion

  @doc """
  Renders the fleet overview. Consumes `Still.Status.overview/0` and
  folds in the API version (a web-layer concern, not a context one).
  """
  def render_overview(overview) when is_map(overview) do
    %{data: Map.put(overview, :api_version, APIVersion.current())}
  end

  @doc "Renders the per-server list — see `Still.Status.servers_with_reports/0`."
  def render_servers(entries) when is_list(entries) do
    %{data: Enum.map(entries, &server/1)}
  end

  @doc "Base shape for one server row, connected or not."
  def server(%{server: %Server{} = server, report: nil, metrics: metrics}) do
    %{
      id: server.id,
      name: server.name,
      host: server.host,
      roles: server.roles,
      connection_status: "disconnected",
      connected_at: nil,
      last_seen_at: server.last_seen_at,
      metadata: server.metadata,
      applications: [],
      metrics: metrics_shape(metrics)
    }
  end

  def server(%{server: %Server{} = server, report: report, metrics: metrics})
      when is_map(report) do
    %{
      id: server.id,
      name: server.name,
      host: server.host,
      roles: server.roles,
      connection_status: "connected",
      connected_at: report.connected_at,
      last_seen_at: server.last_seen_at,
      metadata: server.metadata,
      applications: Enum.map(report.applications, &server_application/1),
      metrics: metrics_shape(metrics)
    }
  end

  @doc """
  Serializes the latest node-metrics sample. `nil` when no sample has
  arrived for this server yet (e.g. a fresh connection or a collector
  that just restarted).
  """
  def metrics_shape(nil), do: nil

  def metrics_shape(%{} = metrics) do
    %{
      at: Map.get(metrics, :at),
      cpu_pct: Map.get(metrics, :cpu_pct),
      mem_pct: Map.get(metrics, :mem_pct),
      disk_pct: Map.get(metrics, :disk_pct)
    }
  end

  @doc "One element of a connected server's `applications` list."
  def server_application(app) when is_map(app) do
    %{
      application_name: app.application_name,
      current_version: Map.get(app, :current_version),
      active_slot: Map.get(app, :active_slot),
      active_port: Map.get(app, :active_port),
      health: Map.get(app, :health),
      last_health_check_at: Map.get(app, :last_health_check_at),
      pid: Map.get(app, :pid),
      active_state: Map.get(app, :active_state),
      active_enter_at: Map.get(app, :active_enter_at)
    }
  end

  @doc "Renders the per-application list — see `Still.Status.applications_with_reports/0`."
  def render_applications(entries) when is_list(entries) do
    %{data: Enum.map(entries, &application/1)}
  end

  @doc "Base shape for one application's desired-vs-actual row."
  def application(%{application: app, assigned: assigned, metrics: metrics}) do
    servers = Enum.map(assigned, &application_server/1)
    healthy = Enum.count(servers, &(&1.health == :healthy))

    %{
      name: app.name,
      type: app.type,
      domain: app.domain,
      min_healthy: app.min_healthy,
      healthy_server_count: healthy,
      servers: servers,
      metrics: application_metrics(metrics)
    }
  end

  @doc """
  Rolling Caddy request metrics for an application — the dashboard
  shows the window total (e.g. "req 24h") and renders `samples` as a
  sparkline. Empty payload when the scraper hasn't recorded anything.
  """
  def application_metrics(%{window_total: total, samples: samples}) do
    %{window_total: total, samples: samples}
  end

  @doc "One assigned server's desired-vs-actual row inside an application."
  def application_server({row, nil, nil}) do
    %{
      server_id: row.server_id,
      desired_version: row.desired_version,
      current_version: nil,
      health: nil,
      connected: false
    }
  end

  def application_server({row, _report, live}) do
    %{
      server_id: row.server_id,
      desired_version: row.desired_version,
      current_version: live && Map.get(live, :current_version),
      health: live && Map.get(live, :health),
      connected: true
    }
  end
end
