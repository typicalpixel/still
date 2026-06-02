defmodule Still.Dev.Standalone do
  @moduledoc false

  # Dev-only helpers for testing the dashboard against a faked single-node
  # install — no real agent or `mix release` needed. NOT wired into the
  # supervision tree; call these from an `iex -S mix phx.server` session:
  #
  #     Still.Dev.Standalone.seed()         # admin + server + apps + deploy history, connected
  #     Still.Dev.Standalone.disconnect()   # take the host offline (realtime)
  #     Still.Dev.Standalone.reconnect()    # bring it back online
  #     Still.Dev.Standalone.reset()        # remove seeded apps, server, and dev admin
  #
  # seed/0 is idempotent: existing rows are left alone, so re-running it is
  # safe. reset/0 is the inverse — it disconnects, then deletes the seeded
  # apps, the server, and the dev admin, returning the instance to fresh.

  require Logger

  alias Still.Accounts
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Fleet

  @version "1.0.0"
  @admin_email "dev@example.com"
  @admin_password "devpassword12"

  # CaddyMetricsScraper's ETS table (its @table). Hardcoded because faking
  # traffic must stay confined to this dev module — we write into the table
  # from inside the owning process via :sys.replace_state since it's :protected.
  @caddy_metrics_table :caddy_metrics

  # six:ignore:start

  @doc "Seeds an admin login, a standalone server, sample apps with deploy history, and announces them as connected."
  def seed do
    ensure_admin()
    server = ensure_server()
    Enum.each(sample_apps(), &ensure_app(&1, server))
    Enum.each(sample_apps(), &seed_traffic(&1.name))
    announce(server)
    Logger.info("[dev standalone] sign in with #{@admin_email} / #{@admin_password}")
    :ok
  end

  @doc "Takes the simulated host offline (broadcasts server_disconnected for the realtime views)."
  def disconnect do
    AgentConnectionManager.agent_disconnected(server_id())
    :ok
  end

  @doc "Brings the simulated host back online with its current apps."
  def reconnect do
    case Fleet.get_server(server_id()) do
      nil -> {:error, :not_seeded}
      server -> announce(server)
    end
  end

  @doc "Undoes seed/0: disconnects, then removes the seeded apps, server, and dev admin (back to a fresh instance)."
  def reset do
    disconnect()
    Enum.each(sample_apps(), &delete_app/1)
    delete_server()
    delete_admin()
    :ok
  end

  defp server_id, do: Application.fetch_env!(:still, :server_id)

  defp delete_app(attrs) do
    clear_traffic(attrs.name)

    case Applications.get_application_by_name(attrs.name) do
      nil ->
        :ok

      app ->
        app
        |> Applications.list_application_servers()
        |> Enum.each(&Applications.unassign_server(Actor.system(), &1))

        Applications.delete_application(Actor.system(), app)
    end
  end

  # Injects ~24h of per-minute traffic samples (a daily wave, offset per app
  # so the three lines differ) so the dashboard sparkline has something to
  # draw. The seeded apps have no real Caddy route, so the scraper's tick
  # never overwrites these.
  defp seed_traffic(app_name) do
    inject_traffic(app_name, fake_traffic_series(:erlang.phash2(app_name, 12)))
  end

  defp clear_traffic(app_name), do: inject_traffic(app_name, [])

  defp inject_traffic(app_name, samples) do
    case Process.whereis(Still.CaddyMetricsScraper) do
      nil ->
        :ok

      pid ->
        # The scraper owns a :protected ETS table; run the write inside its
        # process so we don't have to add a seam to the production module.
        :sys.replace_state(pid, fn state ->
          :ets.insert(@caddy_metrics_table, {app_name, %{history: samples}})
          state
        end)

        :ok
    end
  end

  defp fake_traffic_series(offset) do
    minutes = 24 * 60
    now = DateTime.utc_now()

    for i <- 0..(minutes - 1) do
      hour = div(i, 60)
      wave = 45 + round(35 * :math.sin((hour + offset) / 24 * 2 * :math.pi()))
      jitter = rem(i * 7 + offset * 13, 21) - 10
      delta = max(wave + jitter, 0)
      %{at: DateTime.add(now, -(minutes - 1 - i) * 60, :second), delta: delta, total: 0}
    end
  end

  defp delete_server do
    case Fleet.get_server(server_id()) do
      nil -> :ok
      server -> Fleet.delete_server(Actor.system(), server)
    end
  end

  defp delete_admin do
    case Enum.find(Accounts.list_users(), &(&1.email == @admin_email)) do
      nil -> :ok
      user -> Accounts.delete_user(Actor.system(), user)
    end
  end

  defp ensure_admin do
    unless Accounts.has_users?() do
      {:ok, _user} =
        Accounts.create_user(Actor.system(), %{
          name: "Dev Admin",
          email: @admin_email,
          role: :admin,
          password: @admin_password
        })
    end
  end

  defp ensure_server do
    {:ok, server} =
      Fleet.ensure_server(Actor.system(), %{
        id: server_id(),
        name: "standalone",
        host: "localhost",
        roles: ["controller", "ingress", "application"]
      })

    server
  end

  defp sample_apps do
    [
      %{
        name: "orchard-api",
        type: :elixir_release,
        domain: "api.orchard.test",
        path_prefix: "/api",
        exec_command: "bin/orchard start",
        health_check: %{path: "/health", interval_ms: 5_000, deadline_ms: 3_000},
        artifact_source: %{type: :unauthenticated_url}
      },
      %{
        name: "orchard-web",
        type: :static_site,
        domain: "orchard.test",
        artifact_source: %{type: :unauthenticated_url}
      },
      %{
        name: "billing-worker",
        type: :process,
        domain: "billing.orchard.test",
        exec_command: "bin/billing start",
        health_check: %{path: "/up", interval_ms: 5_000, deadline_ms: 3_000},
        artifact_source: %{type: :unauthenticated_url}
      }
    ]
  end

  defp ensure_app(attrs, server) do
    case Applications.get_application_by_name(attrs.name) do
      nil -> create_app(attrs, server)
      existing -> existing
    end
  end

  defp create_app(attrs, server) do
    {:ok, app} = Applications.create_application(Actor.system(), attrs)
    {:ok, _assignment} = Applications.assign_server(Actor.system(), app, server)
    Applications.set_desired_version_for_all(app, @version)
    seed_deployment(app)
    app
  end

  defp seed_deployment(app) do
    {:ok, deployment} =
      Deployments.create_deployment(Actor.system(), app, %{
        version: @version,
        artifact_url: "https://artifacts.orchard.test/#{app.name}-#{@version}.tar.gz",
        initiated_by: "dev:seed"
      })

    Enum.each(deployment.steps, &Deployments.complete_deployment_step!/1)
    Deployments.complete_deployment!(deployment)
  end

  defp announce(server) do
    AgentConnectionManager.agent_connected(%{
      server_id: server.id,
      node: Node.self(),
      connected_at: DateTime.utc_now(),
      system_info: %{
        hostname: "localhost",
        os: "Linux",
        cpu_count: 8,
        memory_mb: 16_384,
        disk_free_mb: 120_000,
        agent_version: "dev"
      },
      applications: current_apps(server.id)
    })

    :ok
  end

  defp current_apps(server_id) do
    apps_by_name = Map.new(Applications.list_applications(), &{&1.name, &1})

    Applications.list_all_assignments()
    |> Enum.filter(&(&1.server_id == server_id))
    |> Enum.map(fn assignment ->
      app = Map.fetch!(apps_by_name, assignment.application_name)
      app_report(app, assignment.desired_version || @version)
    end)
  end

  defp app_report(app, version) do
    %{
      application_name: app.name,
      type: app.type,
      active_slot: :blue,
      active_port: 20_000,
      current_version: version,
      previous_version: nil,
      last_health_check_at: DateTime.utc_now(),
      health: :healthy,
      pid: 1234,
      active_state: "running",
      active_enter_at: DateTime.utc_now()
    }
  end

  # six:ignore:stop
end
