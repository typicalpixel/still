defmodule Still.Status do
  @moduledoc """
  Reads that combine desired state (from the DB) with actual state
  (from `AgentConnectionManager`'s ETS table). The rest of the code
  keeps those two worlds separate — this module is the designated
  merge point, powering the `/api/status/*` endpoints.

  Returns plain data structures; the shape for the wire lives in
  `StillWeb.StatusJSON`.
  """

  alias Still.Accounts
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.CaddyMetricsScraper
  alias Still.Fleet
  alias Still.MetricsCollector

  @doc """
  Fleet-level overview. Safe to call before any user exists — callers
  use `bootstrap_required` to branch the UI.
  """
  def overview do
    servers = Fleet.list_servers()
    connected = Enum.count(servers, &AgentConnectionManager.connected?(&1.id))

    %{
      bootstrap_required: not Accounts.has_users?(),
      server_count: length(servers),
      connected_server_count: connected
    }
  end

  @doc """
  One entry per server with its latest agent report (or `nil` when the
  agent is not connected) and its latest resource-utilization sample
  (or `nil` when no sample has arrived yet).
  """
  def servers_with_reports do
    for server <- Fleet.list_servers() do
      %{
        server: server,
        report: AgentConnectionManager.get_agent_state(server.id),
        metrics: MetricsCollector.latest_for(server.id)
      }
    end
  end

  @doc """
  One entry per application with its per-assigned-server live reports
  and its rolling Caddy request metrics.

  Each entry is a map:

    * `:application` — the application struct
    * `:assigned` — list of `{assignment, agent_report | nil, live_app_state | nil}`
    * `:metrics` — `%{window_total, samples}` with the request count over
      the scraper's rolling window and the sparkline history. Samples
      are maps `%{at, delta, total}`; empty list when no samples exist.
  """
  def applications_with_reports do
    applications = Applications.list_applications()

    assignments_by_name =
      Enum.group_by(Applications.list_all_assignments(), & &1.application_name)

    for app <- applications do
      assigned = Map.get(assignments_by_name, app.name, [])

      %{
        application: app,
        assigned: Enum.map(assigned, &with_report(&1, app.name)),
        metrics: %{
          window_total: CaddyMetricsScraper.window_total(app.name),
          samples: CaddyMetricsScraper.history_for(app.name)
        }
      }
    end
  end

  defp with_report(row, application_name) do
    case AgentConnectionManager.get_agent_state(row.server_id) do
      nil ->
        {row, nil, nil}

      report ->
        live = Enum.find(report.applications, &(&1.application_name == application_name))
        {row, report, live}
    end
  end
end
