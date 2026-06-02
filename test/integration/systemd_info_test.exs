defmodule Still.Integration.SystemdInfoTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.DeploymentManager
  alias Still.Agent.Systemd
  alias Still.IntegrationFixtures

  @application "test-still-systemd-info"

  setup do
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    ports = %{blue: free_port(), green: free_port()}
    {:ok, ports: ports}
  end

  test "info_for/2 returns pid, active_state, and active_enter_at for a running unit",
       %{ports: ports} do
    spec = build_spec("0.0.1-a", ports)
    start_supervised!(DeploymentManager)

    assert {:ok, _} = DeploymentManager.deploy(spec)

    # Deploy always lands on the blue slot first — units are named
    # <application>@<slot>.service under the hood.
    info = Systemd.info_for(@application, :blue)

    assert is_integer(info.pid) and info.pid > 0
    assert info.active_state == "active"
    assert %DateTime{} = info.active_enter_at
  end

  test "info_for/2 returns all-nil values for a unit that doesn't exist",
       %{ports: _ports} do
    info = Systemd.info_for("does-not-exist-#{System.unique_integer([:positive])}", :blue)

    assert info.pid == nil
    assert info.active_state == "inactive"
    assert info.active_enter_at == nil
  end

  defp build_spec(version, ports) do
    %{
      application: @application,
      type: :elixir_release,
      version: version,
      artifact_url: IntegrationFixtures.file_url(:release_a),
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
end
