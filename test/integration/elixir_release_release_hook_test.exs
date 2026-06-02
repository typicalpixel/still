defmodule Still.Integration.ElixirReleaseReleaseHookTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.CaddyManager
  alias Still.Agent.DeploymentManager
  alias Still.Agent.HealthMonitor
  alias Still.IntegrationFixtures

  @application "test-still-release-hook"

  setup do
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    # The module shares one Caddy across its tests; reset the still server's
    # routes so a route written by a sibling test can't leak into this one.
    reset_still_routes()

    ports = %{blue: free_port(), green: free_port()}
    {:ok, ports: ports}
  end

  test "release hook fires after symlink with the new release files on disk and the deploy proceeds normally on success",
       %{caddy: caddy, ports: ports, applications_dir: apps_dir} do
    marker = Path.join(apps_dir, "release-marker")

    spec =
      build_spec(ports, %{
        release: %{
          # Touch the marker only if the new release's `bin/elixir_release` is
          # already on disk via the inactive-slot symlink — proves the hook
          # runs after symlink and that STILL_RELEASE_DIR is the new release.
          script: """
          set -eu
          test -x "$STILL_RELEASE_DIR/bin/elixir_release"
          echo "release=$STILL_VERSION slot=$STILL_TARGET_SLOT" > #{marker}
          """,
          timeout_ms: 10_000
        }
      })

    start_supervised!(HealthMonitor)
    start_supervised!(DeploymentManager)

    assert {:ok, "0.0.1-release-hook"} = DeploymentManager.deploy(spec)
    assert fetch_body(caddy.http_port, "/health") == "ok"

    assert File.exists?(marker), "release hook did not run"
    contents = File.read!(marker)
    assert contents =~ "release=0.0.1-release-hook"
    assert contents =~ ~r/slot=(blue|green)/
  end

  test "release hook failure aborts the deploy before systemctl start and leaves Caddy untouched",
       %{ports: ports} do
    spec =
      build_spec(ports, %{
        release: %{
          script: """
          echo "migration explosion" >&2
          exit 5
          """,
          timeout_ms: 5_000
        }
      })

    start_supervised!(DeploymentManager)

    assert {:error, %{step: :release, reason: reason}} = DeploymentManager.deploy(spec)
    assert reason =~ "release hook exit 5"
    assert reason =~ "migration explosion"

    refute systemd_unit_installed?(@application),
           "systemctl was reached even though the release hook failed"

    refute caddy_has_route_for?(@application)
  end

  defp build_spec(ports, hooks) do
    %{
      application: @application,
      type: :elixir_release,
      version: "0.0.1-release-hook",
      artifact_url: IntegrationFixtures.file_url(:release_a),
      artifact_provider: Still.Artifact.Provider.LocalFile,
      domain: "localhost",
      env_vars: %{},
      exec_command: "bin/elixir_release start",
      exec_start_pre: nil,
      exec_stop: nil,
      user: nil,
      health_check: %{path: "/health", interval_ms: 500, deadline_ms: 30_000},
      hooks: hooks,
      port_blue: ports.blue,
      port_green: ports.green
    }
  end

  defp fetch_body(http_port, path) do
    %{status: 200, body: body} = Req.get!("http://localhost:#{http_port}#{path}", retry: false)
    body
  end

  defp systemd_unit_installed?(application) do
    File.exists?("/etc/systemd/system/#{application}@.service")
  end

  defp reset_still_routes do
    {:ok, config} = CaddyManager.get_config()
    reset = put_in(config, ["apps", "http", "servers", "still", "routes"], [])
    :ok = CaddyManager.load_config(reset)
  end

  defp caddy_has_route_for?(application) do
    {:ok, config} = CaddyManager.get_config()
    routes = get_in(config, ["apps", "http", "servers", "still", "routes"]) || []
    id = "still_app_#{application}"
    Enum.any?(routes, fn route -> Map.get(route, "@id") == id end)
  end
end
