defmodule Still.Integration.ConsolePeerLifecycleTest do
  use Still.IntegrationCase, root: true

  alias Still.Agent.ConsoleManager
  alias Still.Agent.DeploymentManager
  alias Still.IntegrationFixtures

  @application "test-still-console-peer"

  setup ctx do
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    peer = start_agent_peer!(ctx)

    # The test stops the peer itself as its final assertion; tolerate the
    # double stop on teardown.
    on_exit(fn ->
      try do
        stop_agent_peer!(peer)
      catch
        _, _ -> :ok
      end
    end)

    ports = %{blue: free_port(), green: free_port()}
    {:ok, agent: peer, ports: ports}
  end

  test "owner death and agent death both reap the remote PTY", %{agent: agent, ports: ports} do
    assert {:ok, "0.0.1-a"} =
             GenServer.call(
               {DeploymentManager, agent.node},
               {:deploy,
                %{
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
                }},
               120_000
             )

    # (a) A dying owner (LiveView crash, controller restart) reaps the PTY —
    # no orphan `bin/<app> remote` may survive on the host.
    test_pid = self()

    owner =
      spawn(fn ->
        send(test_pid, {:opened, open_console(agent.node)})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:opened, {:ok, sid}}, 30_000
    assert File.exists?("/proc/#{sid}")

    Process.exit(owner, :kill)
    wait_until!(fn -> not File.exists?("/proc/#{sid}") end)

    # (b) A live cross-node session round-trips IEx and dies with the agent.
    assert {:ok, sid2} = open_console(agent.node)
    node_name = "#{@application}-blue@127.0.0.1"
    collect_output(sid2, "iex(#{node_name})")

    ConsoleManager.input(agent.node, sid2, "node()\r")
    collect_output(sid2, ~s(:"#{node_name}"))

    stop_agent_peer!(agent)
    # Layered teardown: app stop → exec terminate → SIGTERM → 5s kill_timeout
    # → SIGKILL, plus exec-port's own exit alarm. Allow the full cascade.
    wait_until!(fn -> not File.exists?("/proc/#{sid2}") end, 30_000)
  end

  defp open_console(node) do
    ConsoleManager.open(node, %{
      application: @application,
      slot: :blue,
      exec_command: "bin/elixir_release start",
      owner: self(),
      user_id: "integration",
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
