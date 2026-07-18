defmodule StillWeb.ApplicationComponentsTest do
  use StillWeb.ConnCase

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import StillWeb.ApplicationComponents

  # Builds a applications_with_reports-shaped entry from a list of slot specs
  # (%{connected:, health:, current:, desired:}).
  defp entry(slots, opts \\ []) do
    %{
      application: %{
        name: opts[:name] || "app",
        min_healthy: opts[:min_healthy] || 1,
        type: opts[:type] || :elixir_release,
        domain: opts[:domain]
      },
      assigned:
        Enum.map(slots, fn s ->
          report = if s[:connected], do: %{}, else: nil

          live =
            if s[:health] || s[:current], do: %{health: s[:health], current_version: s[:current]}

          {%{desired_version: s[:desired]}, report, live}
        end),
      metrics: %{samples: opts[:samples] || []}
    }
  end

  describe "row_health/1" do
    test "health-checked apps read healthy / degraded / unhealthy" do
      assert row_health(entry([%{connected: true, health: :healthy, current: "1", desired: "1"}])) ==
               :healthy

      assert row_health(
               entry([
                 %{connected: true, health: :healthy, current: "1", desired: "1"},
                 %{connected: true, health: :unhealthy, current: "1", desired: "1"}
               ])
             ) == :degraded

      assert row_health(
               entry([%{connected: true, health: :unhealthy, current: "1", desired: "1"}])
             ) ==
               :unhealthy
    end

    test "apps with no successful deploy read undeployed" do
      assert row_health(entry([])) == :undeployed
      assert row_health(entry([%{connected: true}])) == :undeployed
    end

    test "no-probe deployed apps read na (all live), degraded, unhealthy" do
      assert row_health(entry([%{connected: true, current: "1", desired: "1"}])) == :na

      assert row_health(
               entry([
                 %{connected: true, current: "1", desired: "1"},
                 %{connected: false, desired: "1"}
               ])
             ) == :degraded

      assert row_health(entry([%{connected: false, desired: "1"}])) == :unhealthy
    end
  end

  describe "derivations" do
    test "common_version picks the most common version, or an em dash" do
      assert common_version(entry([])) == "—"

      assert common_version(
               entry([
                 %{connected: true, current: "1.0", desired: "1.0"},
                 %{connected: true, current: "1.0", desired: "1.0"},
                 %{connected: true, current: "2.0", desired: "2.0"}
               ])
             ) == "1.0"
    end

    test "live_count uses healthy probes, or deployed bits for no-probe apps" do
      assert live_count(
               entry([
                 %{connected: true, health: :healthy, current: "1", desired: "1"},
                 %{connected: true, health: :unhealthy, current: "1", desired: "1"}
               ])
             ) == 1

      assert live_count(
               entry([
                 %{connected: true, current: "1", desired: "1"},
                 %{connected: false, desired: "1"}
               ])
             ) == 1
    end

    test "health_dot maps a row health to a tone" do
      assert health_dot(:healthy) == :healthy
      assert health_dot(:na) == :healthy
      assert health_dot(:undeployed) == :neutral
      assert health_dot(:degraded) == :warn
      assert health_dot(:unhealthy) == :danger
      assert health_dot(:other) == :neutral
    end

    test "row_health_label reads na as running, undeployed as not deployed" do
      assert row_health_label(:na) == "running"
      assert row_health_label(:undeployed) == "not deployed"
      assert row_health_label(:healthy) == "healthy"
    end

    test "hosts_color_class tints by health" do
      assert hosts_color_class(:degraded) == "text-warning"
      assert hosts_color_class(:unhealthy) == "text-error"
      assert hosts_color_class(:healthy) == ""
    end

    test "traffic buckets samples into 24 points, nil when empty" do
      assert traffic(entry([], samples: [])) == nil

      samples = for i <- 1..10, do: %{at: nil, delta: i, total: i}
      buckets = traffic(entry([], samples: samples))
      assert length(buckets) == 24
      assert Enum.sum(buckets) == Enum.sum(1..10)
    end
  end

  describe "app_table/1" do
    test "renders an empty notice with no apps" do
      assigns = %{apps: []}
      assert rendered_to_string(~H|<.app_table apps={@apps} />|) =~ "No applications yet."
    end

    test "renders a row with version, state, and traffic" do
      apps = [
        entry([%{connected: true, health: :healthy, current: "1.2.3", desired: "1.2.3"}],
          name: "api",
          samples: [%{at: nil, delta: 5, total: 5}]
        )
      ]

      assigns = %{apps: apps}
      html = rendered_to_string(~H|<.app_table apps={@apps} />|)

      assert html =~ "api"
      assert html =~ "1.2.3"
      assert html =~ "healthy"
    end
  end

  describe "application_display/1" do
    test "renders a labelled type chip per runtime" do
      assigns = %{}
      assert rendered_to_string(~H|<.application_display type={:elixir_release} />|) =~ "Elixir"
      assert rendered_to_string(~H|<.application_display type={:static_site} />|) =~ "Static"
      assert rendered_to_string(~H|<.application_display type={:process} />|) =~ "Process"
    end
  end

  describe "applications_table/1" do
    test "renders an empty notice with no apps" do
      assigns = %{apps: [], last_deploys: %{}}

      assert rendered_to_string(
               ~H|<.applications_table apps={@apps} last_deploys={@last_deploys} />|
             ) =~ "No applications yet."
    end

    test "renders a row with type, domain, version, and last deploy" do
      apps = [
        entry([%{connected: true, health: :healthy, current: "1.0.0", desired: "1.0.0"}],
          name: "api",
          type: :elixir_release,
          domain: "api.example.com"
        )
      ]

      assigns = %{
        apps: apps,
        last_deploys: %{"api" => DateTime.add(DateTime.utc_now(), -300, :second)}
      }

      html =
        rendered_to_string(~H|<.applications_table apps={@apps} last_deploys={@last_deploys} />|)

      assert html =~ "api"
      assert html =~ "Elixir"
      assert html =~ "api.example.com"
      assert html =~ "1.0.0"
      assert html =~ "ago"
    end
  end

  describe "app_config/1" do
    test "renders config, including optional fields when set" do
      assigns = %{
        app: %{
          type: :process,
          exec_command: "bin/run",
          exec_start_pre: "bin/run eval Migrate.run",
          exec_stop: "bin/run stop",
          exec_console: "bin/run remote",
          path_prefix: "/v1",
          health_check: %{path: "/health", interval_ms: 5000, deadline_ms: 3000},
          min_healthy: 2,
          artifact_source: %{type: :local_file},
          inserted_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-01-01 00:00:00Z]
        }
      }

      html = rendered_to_string(~H|<.app_config app={@app} />|)
      assert html =~ "process"
      assert html =~ "bin/run"
      assert html =~ "bin/run eval Migrate.run"
      assert html =~ "bin/run stop"
      assert html =~ "bin/run remote"
      assert html =~ "/v1"
      assert html =~ "/health"
      assert html =~ "local_file"
    end

    test "omits optional fields when unset" do
      assigns = %{
        app: %{
          type: :static_site,
          exec_command: nil,
          exec_start_pre: nil,
          exec_stop: nil,
          exec_console: nil,
          path_prefix: nil,
          health_check: nil,
          min_healthy: 1,
          artifact_source: %{type: :unauthenticated_url},
          inserted_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-01-01 00:00:00Z]
        }
      }

      html = rendered_to_string(~H|<.app_config app={@app} />|)
      assert html =~ "static_site"
      refute html =~ "Exec"
      refute html =~ "Health check"
    end
  end

  describe "app_env/1" do
    test "renders sorted env vars" do
      assigns = %{app: %{env_vars: %{"PORT" => "4000", "MIX_ENV" => "prod"}}}
      html = rendered_to_string(~H|<.app_env app={@app} />|)
      assert html =~ "PORT"
      assert html =~ "4000"
    end

    test "shows an empty notice with no env vars" do
      assigns = %{app: %{env_vars: %{}}}
      assert rendered_to_string(~H|<.app_env app={@app} />|) =~ "No environment variables set."
    end
  end

  describe "app_hooks/1" do
    test "renders hooks with their script" do
      assigns = %{
        hooks: [
          %{
            id: "h1",
            event: :pre_deploy,
            timeout_ms: 30_000,
            script: "echo deploying",
            updated_at: ~U[2026-01-01 00:00:00Z]
          }
        ]
      }

      html = rendered_to_string(~H|<.app_hooks hooks={@hooks} />|)
      assert html =~ "Pre-deploy"
      assert html =~ "echo deploying"
    end

    test "shows an empty notice with no hooks" do
      assigns = %{hooks: []}

      assert rendered_to_string(~H|<.app_hooks hooks={@hooks} />|) =~
               "No lifecycle hooks configured."
    end
  end
end
