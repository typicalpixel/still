defmodule Still.Integration.StaticSiteRollingDeployTest do
  use Still.IntegrationCase

  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Events
  alias Still.IntegrationFixtures
  alias Still.Orchestrator

  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  setup tags do
    # This test is the first :integration test to touch the DB, so it needs
    # the SQL sandbox set up in shared mode (required because the Orchestrator
    # spawns a background Task that owns no sandbox connection otherwise).
    Still.DataCase.setup_sandbox(tags)

    # Controller-side processes. Test env does not auto-start them
    # (see config/test.exs) so the test owns their lifetime directly.
    start_supervised!(AgentConnectionManager)
    start_supervised!({Orchestrator, notifier: self()})

    # Subscribe BEFORE spawning peers so we catch their announcement
    # broadcasts (ACM fires `:server_connected` on the `servers:lobby`
    # PubSub topic when it processes `{:agent_connected, report}`).
    Events.subscribe("servers:lobby")

    # DB records: two servers first, so peers can be spawned with their
    # assigned server ids and auto-announce via NodeConnector.
    server_a = server_fixture(%{name: "server-a-#{System.unique_integer([:positive])}"})
    server_b = server_fixture(%{name: "server-b-#{System.unique_integer([:positive])}"})

    # Two self-contained peer agents, each with its own Caddy and
    # applications_dir, each configured to announce under its server id.
    peer_a = start_isolated_agent_peer!(server_id: server_a.id)
    peer_b = start_isolated_agent_peer!(server_id: server_b.id)

    assert_receive {:server_connected, %{server_id: _}}, 5_000
    assert_receive {:server_connected, %{server_id: _}}, 5_000
    assert AgentConnectionManager.connected?(server_a.id)
    assert AgentConnectionManager.connected?(server_b.id)

    app =
      application_fixture(%{
        name: "rolling-deploy-test-#{System.unique_integer([:positive])}",
        type: :static_site,
        domain: "rolling-deploy.test",
        exec_command: nil,
        health_check: nil,
        min_healthy: 1,
        artifact_source: %{type: :local_file}
      })

    {:ok, _} = Applications.assign_server(Actor.system(), app, server_a)
    {:ok, _} = Applications.assign_server(Actor.system(), app, server_b)

    on_exit(fn ->
      stop_isolated_agent_peer!(peer_a)
      stop_isolated_agent_peer!(peer_b)
    end)

    {:ok, app: app, peer_a: peer_a, peer_b: peer_b, server_a: server_a, server_b: server_b}
  end

  test "rolling deploy reaches both agents sequentially and both serve the deployed version",
       %{app: app, peer_a: peer_a, peer_b: peer_b} do
    attrs = %{
      version: "0.0.1-a",
      artifact_url: IntegrationFixtures.file_url(:static_a),
      initiated_by: "integration-test"
    }

    assert {:ok, deployment} = Orchestrator.trigger_deployment(Actor.system(), app, attrs)
    assert deployment.status == :pending

    assert_receive {:deployment_complete, id, :completed}, 60_000
    assert id == deployment.id

    updated = Deployments.get_deployment!(deployment.id)
    assert updated.status == :completed
    assert %DateTime{} = updated.started_at
    assert %DateTime{} = updated.completed_at

    assert fetch_body(peer_a.caddy.http_port, "rolling-deploy.test", "/") =~
             "still-fixture-static vA"

    assert fetch_body(peer_b.caddy.http_port, "rolling-deploy.test", "/") =~
             "still-fixture-static vA"
  end

  defp fetch_body(http_port, host, path) do
    %{status: 200, body: body} =
      Req.get!("http://localhost:#{http_port}#{path}",
        headers: [{"host", host}],
        retry: false
      )

    body
  end
end
