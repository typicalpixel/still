defmodule Still.Integration.StaticSiteDeployTest do
  use Still.IntegrationCase

  alias Still.Agent.DeploymentManager
  alias Still.IntegrationFixtures

  test "deploys a static_site end-to-end and flips the served response through Caddy",
       %{caddy: caddy} do
    spec_a = %{
      application: "integration-static",
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

    start_supervised!(DeploymentManager)

    assert {:ok, "0.0.1-a"} = DeploymentManager.deploy(spec_a)
    assert fetch_home(caddy.http_port) =~ "still-fixture-static vA"

    assert {:ok, "0.0.1-b"} = DeploymentManager.deploy(spec_b)
    assert fetch_home(caddy.http_port) =~ "still-fixture-static vB"
  end

  defp fetch_home(http_port) do
    %{status: 200, body: body} = Req.get!("http://localhost:#{http_port}/", retry: false)
    body
  end
end
