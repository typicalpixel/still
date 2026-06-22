defmodule Still.Integration.ElixirReleaseRestartTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.DeploymentManager
  alias Still.Agent.HealthMonitor
  alias Still.IntegrationFixtures

  @application "test-still-restart"

  setup do
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    ports = %{blue: free_port(), green: free_port()}
    {:ok, ports: ports}
  end

  test "re-boots the current version into the standby slot and keeps serving",
       %{caddy: caddy, ports: ports} do
    spec_a = build_spec("0.0.1-a", :release_a, ports)

    start_supervised!(HealthMonitor)
    start_supervised!(DeploymentManager)

    assert {:ok, "0.0.1-a"} = DeploymentManager.deploy(spec_a)
    assert fetch_body(caddy.http_port, "/") =~ "vA"

    # Restart ignores the spec's version and re-boots the current on-disk version
    # (vA) into the standby slot, health-checks it, then flips Caddy over.
    assert {:ok, "0.0.1-a"} = DeploymentManager.restart(spec_a)
    assert fetch_body(caddy.http_port, "/") =~ "vA"
  end

  test "preserves the rollback target across a restart", %{caddy: caddy, ports: ports} do
    spec_a = build_spec("0.0.1-a", :release_a, ports)
    spec_b = build_spec("0.0.1-b", :release_b, ports)

    start_supervised!(HealthMonitor)
    start_supervised!(DeploymentManager)

    assert {:ok, "0.0.1-a"} = DeploymentManager.deploy(spec_a)
    assert {:ok, "0.0.1-b"} = DeploymentManager.deploy(spec_b)
    assert fetch_body(caddy.http_port, "/") =~ "vB"

    # Restarting vB must not clobber previous_version (still vA).
    assert {:ok, "0.0.1-b"} = DeploymentManager.restart(spec_b)
    assert fetch_body(caddy.http_port, "/") =~ "vB"

    # Rollback still lands on vA — proof the restart kept the rollback target.
    assert {:ok, "0.0.1-a"} = DeploymentManager.rollback(spec_b)
    assert fetch_body(caddy.http_port, "/") =~ "vA"
  end

  test "a restart whose boot fails leaves the running version serving",
       %{caddy: caddy, ports: ports} do
    spec_a = build_spec("0.0.1-a", :release_a, ports)

    start_supervised!(HealthMonitor)
    start_supervised!(DeploymentManager)

    assert {:ok, "0.0.1-a"} = DeploymentManager.deploy(spec_a)
    assert fetch_body(caddy.http_port, "/") =~ "vA"

    # Simulate a config/env change that breaks boot: the standby slot's process
    # exits immediately, so it never passes its health check. Caddy must not flip
    # — the running slot keeps serving vA — which is the whole point of restart.
    broken = %{
      spec_a
      | exec_command: "/bin/sh -c 'exit 1'",
        health_check: %{spec_a.health_check | deadline_ms: 5_000}
    }

    assert {:error, _reason} = DeploymentManager.restart(broken)
    assert fetch_body(caddy.http_port, "/") =~ "vA"
  end

  defp build_spec(version, fixture, ports) do
    %{
      application: @application,
      type: :elixir_release,
      version: version,
      artifact_url: IntegrationFixtures.file_url(fixture),
      artifact_provider: Still.Artifact.Provider.LocalFile,
      domain: "localhost",
      env_vars: %{},
      exec_command: "bin/elixir_release start",
      exec_start_pre: nil,
      exec_stop: nil,
      user: nil,
      health_check: %{path: "/health", interval_ms: 500, deadline_ms: 30_000},
      hooks: %{},
      port_blue: ports.blue,
      port_green: ports.green
    }
  end

  defp fetch_body(http_port, path) do
    %{status: 200, body: body} = Req.get!("http://localhost:#{http_port}#{path}", retry: false)
    body
  end
end
