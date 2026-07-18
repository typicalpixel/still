defmodule Still.Integration.ConsoleAttachTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.ConsoleManager
  alias Still.Agent.DeploymentManager
  alias Still.Agent.HealthMonitor
  alias Still.IntegrationFixtures

  @application "test-still-console"

  setup do
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    ports = %{blue: free_port(), green: free_port()}
    {:ok, ports: ports}
  end

  test "attaches a remote IEx console to a deployed release and round-trips bytes",
       %{ports: ports} do
    start_supervised!(HealthMonitor)
    start_supervised!(DeploymentManager)
    start_supervised!(ConsoleManager)

    assert {:ok, "0.0.1-a"} =
             DeploymentManager.deploy(%{
               application: @application,
               type: :elixir_release,
               version: "0.0.1-a",
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
             })

    assert {:ok, sid} =
             ConsoleManager.open(node(), %{
               application: @application,
               slot: :blue,
               exec_command: "bin/elixir_release start",
               owner: self(),
               rows: 24,
               cols: 80
             })

    node_name = "#{@application}-blue@127.0.0.1"
    prompt = collect_output(sid, "iex(#{node_name})")
    refute prompt =~ "limited shell"

    ConsoleManager.input(node(), sid, "node()\r")
    assert collect_output(sid, ~s(:"#{node_name}"))

    ConsoleManager.close(node(), sid)
    assert_receive {:console_exit, ^sid, _status}, 10_000
    refute File.exists?("/proc/#{sid}")
  end

  test "reports :not_deployed for an unknown application" do
    start_supervised!(ConsoleManager)

    assert {:error, :not_deployed} =
             ConsoleManager.open(node(), %{
               application: "test-still-console-nope",
               slot: :blue,
               exec_command: "bin/whatever start",
               owner: self(),
               rows: 24,
               cols: 80
             })
  end

  defp collect_output(sid, pattern, acc \\ "") do
    if acc =~ pattern do
      acc
    else
      receive do
        {:console_output, ^sid, data} -> collect_output(sid, pattern, acc <> data)
        {:console_exit, ^sid, status} -> flunk("console exited (#{inspect(status)}): #{acc}")
      after
        30_000 -> flunk("timed out waiting for #{inspect(pattern)}; got: #{acc}")
      end
    end
  end
end
