defmodule Still.Integration.MultiAppMultiNodeTest do
  @moduledoc """
  Rolls two static-site applications out to two independent agent peers
  via the Orchestrator and asserts that each agent's local Caddy routes
  the right Host header to the right app. Proves the whole pipeline:
  Orchestrator → Erlang distribution → agent deploy state machine →
  local Caddy Host-matched routes.

  Non-root: both apps are static sites, so no systemctl, no health
  checks. That keeps the test cheap enough to run on every CI build.
  """

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
    Still.DataCase.setup_sandbox(tags)

    start_supervised!(AgentConnectionManager)
    start_supervised!({Orchestrator, notifier: self()})

    Events.subscribe("servers:lobby")

    server_a = server_fixture(%{name: "multi-srv-a-#{System.unique_integer([:positive])}"})
    server_b = server_fixture(%{name: "multi-srv-b-#{System.unique_integer([:positive])}"})

    peer_a = start_isolated_agent_peer!(server_id: server_a.id)
    peer_b = start_isolated_agent_peer!(server_id: server_b.id)

    assert_receive {:server_connected, %{server_id: _}}, 5_000
    assert_receive {:server_connected, %{server_id: _}}, 5_000
    assert AgentConnectionManager.connected?(server_a.id)
    assert AgentConnectionManager.connected?(server_b.id)

    app_site =
      application_fixture(%{
        name: "multi-site-#{System.unique_integer([:positive])}",
        type: :static_site,
        domain: "site.multi.test",
        exec_command: nil,
        health_check: nil,
        min_healthy: 1,
        artifact_source: %{type: :local_file}
      })

    app_marketing =
      application_fixture(%{
        name: "multi-marketing-#{System.unique_integer([:positive])}",
        type: :static_site,
        domain: "marketing.multi.test",
        exec_command: nil,
        health_check: nil,
        min_healthy: 1,
        artifact_source: %{type: :local_file}
      })

    {:ok, _} = Applications.assign_server(Actor.system(), app_site, server_a)
    {:ok, _} = Applications.assign_server(Actor.system(), app_site, server_b)
    {:ok, _} = Applications.assign_server(Actor.system(), app_marketing, server_a)
    {:ok, _} = Applications.assign_server(Actor.system(), app_marketing, server_b)

    on_exit(fn ->
      stop_isolated_agent_peer!(peer_a)
      stop_isolated_agent_peer!(peer_b)
    end)

    {:ok, app_site: app_site, app_marketing: app_marketing, peer_a: peer_a, peer_b: peer_b}
  end

  test "both apps roll out to both agents and each agent's Caddy Host-routes correctly",
       %{app_site: app_site, app_marketing: app_marketing, peer_a: peer_a, peer_b: peer_b} do
    {:ok, site_deploy} =
      Orchestrator.trigger_deployment(Actor.system(), app_site, %{
        version: "0.0.1-site",
        artifact_url: IntegrationFixtures.file_url(:static_a),
        initiated_by: "multi-node-test"
      })

    assert_receive {:deployment_complete, id, :completed}, 60_000
    assert id == site_deploy.id

    {:ok, marketing_deploy} =
      Orchestrator.trigger_deployment(Actor.system(), app_marketing, %{
        version: "0.0.1-marketing",
        artifact_url: IntegrationFixtures.file_url(:static_b),
        initiated_by: "multi-node-test"
      })

    assert_receive {:deployment_complete, id, :completed}, 60_000
    assert id == marketing_deploy.id

    assert Deployments.get_deployment!(site_deploy.id).status == :completed
    assert Deployments.get_deployment!(marketing_deploy.id).status == :completed

    # Each peer's local Caddy must disambiguate the two apps by Host header.
    for peer <- [peer_a, peer_b] do
      assert fetch(peer.caddy.http_port, "site.multi.test", "/") =~ "still-fixture-static vA"

      assert fetch(peer.caddy.http_port, "marketing.multi.test", "/") =~
               "still-fixture-static vB"
    end
  end

  defp fetch(http_port, host, path) do
    %{status: 200, body: body} =
      Req.get!("http://localhost:#{http_port}#{path}",
        headers: [{"host", host}],
        retry: false
      )

    body
  end
end
