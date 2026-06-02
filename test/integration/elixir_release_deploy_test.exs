defmodule Still.Integration.ElixirReleaseDeployTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.DeploymentManager
  alias Still.Agent.HealthMonitor
  alias Still.IntegrationFixtures

  @application "test-still-elixir-release"

  setup do
    # Scrub any leftover systemd state from a prior run before touching anything
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    ports = %{blue: free_port(), green: free_port()}
    {:ok, ports: ports}
  end

  test "deploys an elixir_release end-to-end and flips the served response through Caddy",
       %{caddy: caddy, ports: ports} do
    spec_a = build_spec(:release_a, "0.0.1-a", ports)
    spec_b = build_spec(:release_b, "0.0.1-b", ports)

    start_supervised!(HealthMonitor)
    start_supervised!(DeploymentManager)

    assert {:ok, "0.0.1-a"} = DeploymentManager.deploy(spec_a)
    assert fetch_body(caddy.http_port, "/health") == "ok"
    assert fetch_body(caddy.http_port, "/") =~ "vA"

    assert {:ok, "0.0.1-b"} = DeploymentManager.deploy(spec_b)
    assert fetch_body(caddy.http_port, "/") =~ "vB"
  end

  defp build_spec(fixture, version, ports) do
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
