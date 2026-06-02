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
