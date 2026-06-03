defmodule Still.Integration.ElixirReleaseExecLifecycleTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.DeploymentManager
  alias Still.Agent.HealthMonitor
  alias Still.IntegrationFixtures

  @application "test-still-exec-lifecycle"

  setup do
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    ports = %{blue: free_port(), green: free_port()}
    {:ok, ports: ports}
  end

  # Each test drives a different ExecStart *shape* through a real blue→green flip
  # and confirms `current_%i` resolves the active-slot symlink for that shape.
  # The shared app means each run ends on the green slot, so the next test starts
  # from green and again deploys blue-then-green — the assertions hold regardless
  # of test order. `exec_start_pre` / `exec_stop` ride along in every spec so the
  # rendered unit is checked for those directives too.

  test "relative ExecStart (bin/<app> start) — Still prepends the current_%i slot path",
       %{caddy: caddy, ports: ports, applications_dir: apps_dir} do
    app_dir = Path.join(apps_dir, @application)

    # Relative, so Still resolves it to the absolute slot path itself.
    assert_flip_resolves_slot(
      caddy,
      ports,
      app_dir,
      "bin/elixir_release start",
      "ExecStart=#{app_dir}/current_%i/bin/elixir_release start"
    )
  end

  test "absolute ExecStart into current_%i — passed through verbatim",
       %{caddy: caddy, ports: ports, applications_dir: apps_dir} do
    app_dir = Path.join(apps_dir, @application)
    command = "#{app_dir}/current_%i/bin/elixir_release start"

    # Already absolute, so Still leaves it untouched; only systemd resolves `%i`.
    assert_flip_resolves_slot(caddy, ports, app_dir, command, "ExecStart=#{command}")
  end

  test "prefix-runner ExecStart (stands in for `doppler run --`) — current_%i as an argument",
       %{caddy: caddy, ports: ports, applications_dir: apps_dir} do
    app_dir = Path.join(apps_dir, @application)

    # `doppler run -- <cmd>` is a prefix runner: an absolute wrapper binary that
    # execs a trailing command. `/usr/bin/env --` has the same shape with no token
    # needed, so `current_%i` is resolved by systemd as an *argument* to the
    # wrapper, exactly as in production.
    command = "/usr/bin/env -- #{app_dir}/current_%i/bin/elixir_release start"

    assert_flip_resolves_slot(caddy, ports, app_dir, command, "ExecStart=#{command}")
  end

  defp assert_flip_resolves_slot(caddy, ports, app_dir, exec_command, expected_exec_start) do
    spec_a = build_spec(:release_a, "0.0.1-a", ports, exec_command)
    spec_b = build_spec(:release_b, "0.0.1-b", ports, exec_command)

    start_supervised!(HealthMonitor)
    start_supervised!(DeploymentManager)

    # First deploy lands on blue: systemd expands `%i`→`blue`, follows
    # `current_blue` → releases/0.0.1-a, and the binary serves.
    assert {:ok, "0.0.1-a"} = DeploymentManager.deploy(spec_a)
    assert fetch_body(caddy.http_port, "/") =~ "vA"
    assert File.read_link!(Path.join(app_dir, "current_blue")) =~ "releases/0.0.1-a"

    # Second deploy flips to green with the *same* templated unit: `%i`→`green`,
    # `current_green` → releases/0.0.1-b. Confirms `current_%i` tracks the slot.
    assert {:ok, "0.0.1-b"} = DeploymentManager.deploy(spec_b)
    assert fetch_body(caddy.http_port, "/") =~ "vB"
    assert File.read_link!(Path.join(app_dir, "current_green")) =~ "releases/0.0.1-b"

    content = File.read!("/etc/systemd/system/#{@application}@.service")
    assert content =~ expected_exec_start
    assert content =~ "ExecStartPre=/bin/true"
    assert content =~ "ExecStop=#{app_dir}/current_%i/bin/elixir_release stop"
  end

  defp build_spec(fixture, version, ports, exec_command) do
    %{
      application: @application,
      type: :elixir_release,
      version: version,
      artifact_url: IntegrationFixtures.file_url(fixture),
      artifact_provider: Still.Artifact.Provider.LocalFile,
      domain: "localhost",
      env_vars: %{},
      exec_command: exec_command,
      exec_start_pre: "/bin/true",
      exec_stop: "bin/elixir_release stop",
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
