defmodule Still.Integration.StaticSitePeerDeployTest do
  use Still.IntegrationCase

  alias Still.Agent.DeploymentManager
  alias Still.IntegrationFixtures

  setup ctx do
    peer = start_agent_peer!(ctx)
    on_exit(fn -> stop_agent_peer!(peer) end)
    {:ok, agent: peer}
  end

  test "deploys a static_site to a remote agent peer over Erlang distribution",
       %{caddy: caddy, agent: agent} do
    spec_a = %{
      application: "integration-peer-static",
      type: :static_site,
      version: "0.0.1-a",
      artifact_url: IntegrationFixtures.file_url(:static_a),
      artifact_provider: Still.Artifact.Provider.LocalFile,
      domain: "localhost",
      env_vars: %{},
      exec_command: nil,
      health_check: nil,
      hooks: %{},
      port_blue: nil,
      port_green: nil
    }

    spec_b = %{
      spec_a
      | version: "0.0.1-b",
        artifact_url: IntegrationFixtures.file_url(:static_b)
    }

    assert {:ok, "0.0.1-a"} = deploy_on(agent.node, spec_a)
    assert fetch_home(caddy.http_port) =~ "still-fixture-static vA"

    assert {:ok, "0.0.1-b"} = deploy_on(agent.node, spec_b)
    assert fetch_home(caddy.http_port) =~ "still-fixture-static vB"
  end

  defp deploy_on(node, spec) do
    GenServer.call({DeploymentManager, node}, {:deploy, spec}, 60_000)
  end

  defp fetch_home(http_port) do
    %{status: 200, body: body} = Req.get!("http://localhost:#{http_port}/", retry: false)
    body
  end
end
