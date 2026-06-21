defmodule Still.Integration.ElixirReleaseHealthCheckFailureTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.CaddyManager
  alias Still.Agent.DeploymentManager
  alias Still.IntegrationFixtures

  @application "test-still-health-fail"

  setup do
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    ports = %{blue: free_port(), green: free_port()}
    {:ok, ports: ports}
  end

  test "halts at :health_checking when the endpoint never returns 2xx and leaves Caddy untouched",
       %{ports: ports} do
    spec = build_spec(ports)

    start_supervised!(DeploymentManager)

    assert {:error, %{step: :health_checking, reason: :health_check_timeout}} =
             DeploymentManager.deploy(spec)

    refute caddy_has_route_for?(@application)
  end

  test "fails fast with :app_crash_looped when the unit crash-loops on boot, instead of timing out",
       %{ports: ports} do
    # /bin/false exits non-zero on every start, so the unit crash-loops and
    # trips StartLimitBurst → ActiveState latches to "failed". A generous health
    # deadline (30s) would mask the crash as a slow boot under the old polling;
    # the fix consults the unit and bails the moment it goes failed.
    spec =
      build_spec(ports)
      |> Map.merge(%{
        version: "0.0.1-crash",
        exec_command: "/bin/false",
        health_check: %{path: "/health", interval_ms: 250, deadline_ms: 30_000}
      })

    start_supervised!(DeploymentManager)

    started_at = System.monotonic_time(:millisecond)
    assert {:error, %{step: :health_checking, reason: :app_crash_looped}} =
             DeploymentManager.deploy(spec)

    elapsed = System.monotonic_time(:millisecond) - started_at

    # It bailed on the failed unit, not on the 30s HTTP deadline.
    assert elapsed < spec.health_check.deadline_ms

    refute caddy_has_route_for?(@application)

    # The 2s restart backoff is what keeps the crash-loop legible (§2.1).
    unit_file = File.read!("/etc/systemd/system/#{@application}@.service")
    assert unit_file =~ "RestartSec=2s"
  end

  defp build_spec(ports) do
    %{
      application: @application,
      type: :elixir_release,
      version: "0.0.1-fail",
      artifact_url: IntegrationFixtures.file_url(:release_a),
      artifact_provider: Still.Artifact.Provider.LocalFile,
      domain: "localhost",
      env_vars: %{},
      exec_command: "bin/elixir_release start",
      exec_start_pre: nil,
      exec_stop: nil,
      user: nil,
      # Point the health check at a path the fixture doesn't serve, so every
      # poll returns 404 and the step eventually times out. Short timeout so
      # the test doesn't wait long.
      health_check: %{path: "/does-not-exist", interval_ms: 200, deadline_ms: 2_000},
      hooks: %{},
      port_blue: ports.blue,
      port_green: ports.green
    }
  end

  defp caddy_has_route_for?(application) do
    {:ok, config} = CaddyManager.get_config()
    routes = get_in(config, ["apps", "http", "servers", "still", "routes"]) || []
    id = "still_app_#{application}"
    Enum.any?(routes, fn route -> Map.get(route, "@id") == id end)
  end
end
