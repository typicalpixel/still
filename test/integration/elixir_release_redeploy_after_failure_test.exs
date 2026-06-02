defmodule Still.Integration.ElixirReleaseRedeployAfterFailureTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.DeploymentManager
  alias Still.Agent.HealthMonitor
  alias Still.IntegrationFixtures

  @application "test-still-redeploy-reexec"

  @good_health %{path: "/health", interval_ms: 500, deadline_ms: 30_000}
  # A path the fixture never serves, so the deploy fails at :health_checking
  # AFTER `start` has already brought the slot's unit up.
  @bad_health %{path: "/does-not-exist", interval_ms: 200, deadline_ms: 2_000}

  setup do
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    ports = %{blue: free_port(), green: free_port()}
    {:ok, ports: ports}
  end

  # Regression for SB-1. A deploy that fails its health check leaves the target
  # slot's systemd unit ACTIVE running the old release, with state.json never
  # advanced — so the next deploy targets the SAME slot. The slot's unit is
  # already active, and `systemctl start` on an active unit is a no-op: it would
  # silently keep serving the old code even though the symlink now points at the
  # new release. `start/1` must `restart` (re-exec) instead.
  test "redeploy after a failed health check re-execs the slot with the new release",
       %{caddy: caddy, ports: ports} do
    start_supervised!(HealthMonitor)
    start_supervised!(DeploymentManager)

    # Deploy vA pointed at a health path it never serves → fails after `start`,
    # leaving blue's unit active on vA and state.json unwritten.
    assert {:error, %{step: :health_checking}} =
             DeploymentManager.deploy(build_spec(:release_a, "0.0.1-a", ports, @bad_health))

    # Redeploy vB with a good health check. state.json never advanced, so this
    # targets the SAME slot — whose unit is already active. Only a `restart`
    # re-execs it onto vB.
    assert {:ok, "0.0.1-b"} =
             DeploymentManager.deploy(build_spec(:release_b, "0.0.1-b", ports, @good_health))

    # vB must be what's served — not the stale vA the failed deploy left running.
    assert fetch_body(caddy.http_port, "/health") == "ok"
    assert fetch_body(caddy.http_port, "/") =~ "vB"
  end

  defp build_spec(fixture, version, ports, health_check) do
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
      health_check: health_check,
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
