defmodule Still.Dev.MapleDemo do
  @moduledoc false

  # Dev-only seed for marketing screenshots — a realistic "Maple" company fleet.
  # NOT wired into the supervision tree. Run from `iex -S mix phx.server`:
  #
  #     Still.Dev.MapleDemo.seed()    # wipe everything, then build the Maple demo
  #     Still.Dev.MapleDemo.reset()   # tear the demo down again
  #
  # Most of what the dashboard shows (connected agents, CPU/mem/disk, per-app
  # health, the in-flight deploy, traffic, the activity feed) lives in in-memory
  # ETS, not the DB — so this must run inside the live server node, and that
  # state is lost on restart (re-run seed/0). DB rows persist.

  require Logger

  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Deployments.{Deployment, DeploymentStep}
  alias Still.EventLog
  alias Still.Fleet
  alias Still.MetricsCollector
  alias Still.Repo

  # six:ignore:start

  @servers [
    %{
      name: "maple-edge-1",
      host: "10.20.0.5",
      roles: ["controller", "ingress"],
      cpu: 12,
      mem: 38,
      disk: 41
    },
    %{
      name: "maple-app-1",
      host: "10.20.0.11",
      roles: ["application"],
      cpu: 27,
      mem: 54,
      disk: 49
    },
    %{
      name: "maple-app-2",
      host: "10.20.0.12",
      roles: ["application"],
      cpu: 24,
      mem: 51,
      disk: 47
    },
    %{name: "maple-app-3", host: "10.20.0.13", roles: ["application"], cpu: 9, mem: 33, disk: 44}
  ]

  @app_nodes ~w(maple-app-1 maple-app-2 maple-app-3)

  @imgproxy_log """
  → downloading maple-imgproxy-1.2.0.tar.gz (8.4 MB)
  ✓ unpacked → releases/1.2.0
  → starting maple-imgproxy@green on :8421
    imgproxy 1.2.0 listening on 0.0.0.0:8421
  → health check GET /_health … 200 (118ms)
  ✓ green healthy — switching traffic\
  """

  @doc "Wipes all data + in-memory state, then seeds the Maple demo fleet, connected."
  def seed do
    wipe()
    servers = Enum.into(@servers, %{}, fn s -> {s.name, create_server(s)} end)
    Enum.each(apps(), &create_app(&1, servers))
    deployments = seed_deployments()
    seed_metrics(servers)
    Enum.each(["maple-web", "maple-api", "maple-marketing", "maple-imgproxy"], &seed_traffic/1)
    announce(servers)
    set_demo_logs(deployments)

    # Everything above emits its own audit events into the in-memory feed at
    # "now"; drain them, wipe the feed, then record just the deploy activity we
    # want shown (backdated) so the dashboard feed reads cleanly.
    flush()
    clear_table(Still.EventLog, :event_log)
    Enum.each(deployments, &record_event/1)
    flush()
    Logger.info("[maple demo] seeded — sign in and capture (dark mode).")
    :ok
  end

  @doc "Tears the demo down: clears in-memory state and deletes every app, server, and deployment."
  def reset do
    wipe()
    Application.delete_env(:still, :demo_deploy_logs)
    :ok
  end

  # ── wipe ──────────────────────────────────────────────────────────────────

  defp wipe do
    clear_table(Still.AgentConnectionManager, :agent_state)
    clear_table(Still.MetricsCollector, :node_metrics)
    clear_table(Still.EventLog, :event_log)
    clear_table(Still.CaddyMetricsScraper, :caddy_metrics)

    Repo.delete_all(DeploymentStep)
    Repo.delete_all(Deployment)

    for app <- Applications.list_applications() do
      app
      |> Applications.list_application_servers()
      |> Enum.each(&Applications.unassign_server(Actor.system(), &1))

      Applications.delete_application(Actor.system(), app)
    end

    Enum.each(Fleet.list_servers(), &Fleet.delete_server(Actor.system(), &1))
    :ok
  end

  defp clear_table(process, table) do
    case Process.whereis(process) do
      nil ->
        :ok

      pid ->
        :sys.replace_state(pid, fn state ->
          :ets.delete_all_objects(table)
          state
        end)
    end

    :ok
  end

  # ── servers ───────────────────────────────────────────────────────────────

  defp create_server(attrs) do
    {:ok, server} =
      Fleet.create_server(Actor.system(), Map.take(attrs, [:name, :host, :roles]))

    server
  end

  # ── applications ──────────────────────────────────────────────────────────

  defp apps do
    [
      %{
        name: "maple-web",
        type: :elixir_release,
        domain: "app.maplehq.com",
        version: "2.8.1",
        exec_command: "bin/maple_web start",
        health_check: %{path: "/_health", interval_ms: 5_000, deadline_ms: 3_000},
        min_healthy: 2,
        env_vars: %{
          "DATABASE_URL" => "ecto://maple:s3cr3t-fake@10.20.0.30:5432/maple_prod",
          "SECRET_KEY_BASE" => "FAKExGk2pQ7n0aVdY9wZ1cR4tB6uH8jL3mN5sP7qW2eK0oI",
          "PHX_HOST" => "app.maplehq.com",
          "POOL_SIZE" => "10"
        }
      },
      %{
        name: "maple-api",
        type: :elixir_release,
        domain: "api.maplehq.com",
        version: "2.8.1",
        exec_command: "bin/maple_api start",
        health_check: %{path: "/_health", interval_ms: 5_000, deadline_ms: 3_000},
        min_healthy: 2,
        env_vars: %{
          "DATABASE_URL" => "ecto://maple:s3cr3t-fake@10.20.0.30:5432/maple_prod",
          "SECRET_KEY_BASE" => "FAKEqW2eK0oI7n0aVdY9wZ1cR4tB6uH8jL3mN5sP7xGk2pQ",
          "PORT" => "4001"
        }
      },
      %{
        name: "maple-marketing",
        type: :static_site,
        domain: "www.maplehq.com",
        version: "1.14.0",
        min_healthy: 1,
        env_vars: %{}
      },
      %{
        name: "maple-worker",
        type: :process,
        domain: "jobs.maplehq.com",
        version: "0.9.3",
        exec_command: "/usr/local/bin/maple-worker",
        health_check: %{path: "/up", interval_ms: 10_000, deadline_ms: 3_000},
        min_healthy: 1,
        env_vars: %{
          "DATABASE_URL" => "ecto://maple:s3cr3t-fake@10.20.0.30:5432/maple_prod",
          "REDIS_URL" => "redis://10.20.0.31:6379/0",
          "CONCURRENCY" => "8"
        }
      },
      %{
        name: "maple-imgproxy",
        type: :process,
        domain: "img.maplehq.com",
        version: "1.2.0",
        exec_command: "/usr/local/bin/maple-imgproxy",
        health_check: %{path: "/_health", interval_ms: 5_000, deadline_ms: 3_000},
        min_healthy: 2,
        env_vars: %{
          "IMGPROXY_KEY" => "FAKE-3f9a…",
          "IMGPROXY_SALT" => "FAKE-7c21…",
          "IMGPROXY_S3_BUCKET" => "maple-images"
        }
      }
    ]
  end

  defp create_app(attrs, servers) do
    create_attrs =
      Map.merge(Map.delete(attrs, :version), %{artifact_source: %{type: :unauthenticated_url}})

    {:ok, app} = Applications.create_application(Actor.system(), create_attrs)

    for node <- @app_nodes do
      {:ok, _} = Applications.assign_server(Actor.system(), app, servers[node])
    end

    Applications.set_desired_version_for_all(app, attrs.version)
    app
  end

  # ── deployments + activity feed ─────────────────────────────────────────────

  defp seed_deployments do
    now = DateTime.utc_now()
    server_names = Map.new(Fleet.list_servers(), &{&1.id, &1.name})

    rows = [
      %{
        app: "maple-imgproxy",
        version: "1.2.0",
        status: :in_progress,
        by: "api:ci@maplehq.com",
        source: "ci:github@9f2c1ab",
        at: -34,
        steps: :in_flight
      },
      %{
        app: "maple-web",
        version: "2.8.1",
        status: :completed,
        by: "user:thomas@maplehq.com",
        source: "git:main@a1b2c3d",
        at: -14 * 60,
        dur: 41
      },
      %{
        app: "maple-marketing",
        version: "1.14.0",
        status: :completed,
        by: "api:ci@maplehq.com",
        source: "ci:github@77f0e21",
        at: -3600,
        dur: 22
      },
      %{
        app: "maple-api",
        version: "2.8.0",
        status: :completed,
        by: "user:thomas@maplehq.com",
        source: "git:main@c4d5e6f",
        at: -3 * 3600,
        dur: 38
      },
      %{
        app: "maple-worker",
        version: "0.9.3",
        status: :completed,
        by: "api:ci@maplehq.com",
        source: "ci:nightly",
        at: -26 * 3600,
        dur: 17
      },
      %{
        app: "maple-api",
        version: "2.7.9",
        status: :rolled_back,
        by: "user:thomas@maplehq.com",
        source: "rollback",
        at: -2 * 24 * 3600,
        dur: 12
      }
    ]

    Enum.map(rows, &seed_deployment(&1, now, server_names))
  end

  defp seed_deployment(row, now, server_names) do
    app = Applications.get_application_by_name(row.app)
    at = DateTime.add(now, row.at, :second)

    {:ok, deployment} =
      Deployments.create_deployment(Actor.system(), app, %{
        version: row.version,
        artifact_url: "https://artifacts.maplehq.com/#{row.app}-#{row.version}.tar.gz",
        initiated_by: row.by,
        source: row.source
      })

    started = at
    completed = if row[:dur], do: DateTime.add(at, row.dur, :second), else: nil

    deployment
    |> Ecto.Changeset.change(%{
      status: row.status,
      started_at: started,
      completed_at: completed,
      inserted_at: at
    })
    |> Repo.update!()

    seed_steps(deployment, row, server_names, now)
    %{app: row.app, id: deployment.id, app_name: app.name, status: row.status, at: at}
  end

  # Completed/rolled_back: every host done. In-flight imgproxy: app-1/app-2 done,
  # app-3 still switching (2/3 → ~67%).
  defp seed_steps(%{steps: steps}, %{steps: :in_flight}, server_names, now) do
    Enum.each(steps, fn step ->
      attrs =
        case server_names[step.server_id] do
          "maple-app-1" ->
            %{
              status: :completed,
              started_at: DateTime.add(now, -34, :second),
              completed_at: DateTime.add(now, -12, :second)
            }

          "maple-app-2" ->
            %{
              status: :completed,
              started_at: DateTime.add(now, -30, :second),
              completed_at: DateTime.add(now, -6, :second)
            }

          _ ->
            %{status: :switching, started_at: DateTime.add(now, -8, :second), completed_at: nil}
        end

      step |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end)
  end

  defp seed_steps(
         %{steps: steps, started_at: started, completed_at: completed},
         _row,
         _names,
         _now
       ) do
    Enum.each(steps, fn step ->
      step
      |> Ecto.Changeset.change(%{
        status: :completed,
        started_at: started,
        completed_at: completed
      })
      |> Repo.update!()
    end)
  end

  defp record_event(deploy) do
    EventLog.record(%{
      type: :deployment_updated,
      at: deploy.at,
      payload: %{
        status: to_string(deploy.status),
        application_name: deploy.app_name,
        deployment_id: deploy.id
      }
    })
  end

  # ── metrics + traffic ───────────────────────────────────────────────────────

  defp seed_metrics(servers) do
    at = DateTime.utc_now()

    Enum.each(@servers, fn s ->
      MetricsCollector.record(%{
        server_id: servers[s.name].id,
        at: at,
        cpu_pct: s.cpu,
        mem_pct: s.mem,
        disk_pct: s.disk
      })
    end)
  end

  defp seed_traffic(app_name) do
    case Process.whereis(Still.CaddyMetricsScraper) do
      nil ->
        :ok

      pid ->
        series = fake_traffic_series(:erlang.phash2(app_name, 12))

        :sys.replace_state(pid, fn state ->
          :ets.insert(:caddy_metrics, {app_name, %{history: series}})
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

  # ── agent reports (connection + per-app live state) ──────────────────────────

  defp announce(servers) do
    now = DateTime.utc_now()

    Enum.each(@servers, fn s ->
      AgentConnectionManager.agent_connected(%{
        server_id: servers[s.name].id,
        node: :"#{s.name}@10.20.0",
        connected_at: DateTime.add(now, -rand_offset(s.name), :second),
        system_info: %{
          hostname: s.name,
          os: "Linux",
          cpu_count: 8,
          memory_mb: 32_768,
          disk_free_mb: 400_000,
          agent_version: "1.4.2"
        },
        applications: node_apps(s.name, now)
      })
    end)
  end

  # Stable per-host "connected N min ago" jitter without Date/random in the script.
  defp rand_offset(name), do: rem(:erlang.phash2(name, 1800), 1800) + 120

  defp node_apps(node, _now) when node not in @app_nodes, do: []

  defp node_apps(node, now) do
    img = imgproxy_state(node)

    [
      app_state("maple-web", "2.8.1", :blue, 4000, now),
      app_state("maple-api", "2.8.1", :green, 4001, now),
      app_state("maple-marketing", "1.14.0", :blue, nil, now),
      app_state("maple-worker", "0.9.3", :blue, nil, now),
      app_state("maple-imgproxy", img.version, img.slot, 8421, now)
    ]
  end

  defp imgproxy_state("maple-app-3"), do: %{version: "1.1.9", slot: :blue}
  defp imgproxy_state(_node), do: %{version: "1.2.0", slot: :green}

  defp app_state(name, version, slot, port, now) do
    %{
      application_name: name,
      active_slot: slot,
      active_port: port,
      current_version: version,
      previous_version: nil,
      last_health_check_at: now,
      health: :healthy,
      pid: 4321,
      active_state: "running",
      active_enter_at: DateTime.add(now, -3600, :second)
    }
  end

  # ── demo deploy log (screenshot source for the in-flight deploy) ─────────────

  defp set_demo_logs(deployments) do
    case Enum.find(deployments, &(&1.app == "maple-imgproxy")) do
      nil -> :ok
      %{id: id} -> Application.put_env(:still, :demo_deploy_logs, %{id => @imgproxy_log})
    end
  end

  # Sync the in-memory casts so everything's visible before the user captures.
  defp flush do
    for p <- [
          Still.AgentConnectionManager,
          Still.MetricsCollector,
          Still.EventLog,
          Still.CaddyMetricsScraper
        ],
        pid = Process.whereis(p),
        do: :sys.get_state(pid)

    :ok
  end

  # six:ignore:stop
end
