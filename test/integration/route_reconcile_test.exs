defmodule Still.Integration.RouteReconcileTest do
  @moduledoc """
  Proves a domain change rebuilds the serving Caddy route without a
  redeploy: after `reconcile_route/1` the new host serves the app and the
  old host no longer matches it. Regression test for domain/path_prefix
  changes never reaching the agent's `still_app_*` route.
  """
  use Still.IntegrationCase

  alias Still.Agent.DeploymentManager
  alias Still.IntegrationFixtures

  test "reconcile_route re-points the served host after a domain change",
       %{caddy: caddy} do
    spec = %{
      application: "reconcile-integration",
      type: :static_site,
      version: "0.0.1-a",
      artifact_url: IntegrationFixtures.file_url(:static_a),
      artifact_provider: Still.Artifact.Provider.LocalFile,
      domain: "old.example.test",
      env_vars: %{},
      exec_command: nil,
      health_check: nil,
      hooks: %{},
      port_blue: nil,
      port_green: nil
    }

    start_supervised!(DeploymentManager)

    assert {:ok, "0.0.1-a"} = DeploymentManager.deploy(spec)
    assert %{status: 200, body: body} = get_host(caddy.http_port, "old.example.test")
    assert body =~ "still-fixture-static vA"

    route_spec = %{
      application: spec.application,
      type: :static_site,
      domain: "new.example.test",
      path_prefix: nil
    }

    assert {:ok, :reconciled} = DeploymentManager.reconcile_route(route_spec)

    # The new host now serves the app from the same active slot...
    assert %{status: 200, body: new_body} = get_host(caddy.http_port, "new.example.test")
    assert new_body =~ "still-fixture-static vA"

    # ...and the old host no longer matches the app route. It now falls
    # through to the catch-all the deploy keeps pinned last, which serves
    # the "Still" page instead of the app.
    assert %{body: old_body} = get_host(caddy.http_port, "old.example.test")
    refute old_body =~ "still-fixture-static vA"
    assert old_body == "Still"
  end

  defp get_host(http_port, host) do
    Req.get!("http://localhost:#{http_port}/", headers: [{"host", host}], retry: false)
  end
end
