defmodule Still.Integration.IngressReconcilerIntegrationTest do
  @moduledoc """
  End-to-end: run the real `IngressReconciler` against a real Caddy
  and a real DB. Proves that assigning a server to an application
  causes a correctly-shaped `still_ingress_<app>` route to appear in
  Caddy, and that unassigning removes it.

  This test doesn't exercise distributed Erlang or peer agents —
  `list_routes/0` reads DB rows and the reconciler writes the route
  directly to the one Caddy started by the test harness. For the
  multi-node path through Orchestrator + distribution, see the
  existing `multi_app_multi_node_test.exs`; this test is specifically
  about controller-side ingress config reconciliation.
  """

  use Still.IntegrationCase

  alias Still.Agent.CaddyManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.IngressReconciler

  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  setup tags do
    Still.DataCase.setup_sandbox(tags)

    # Reset the harness's "still" server to a known-good state so
    # previous tests in this module don't leak ingress routes.
    {:ok, config} = CaddyManager.get_config()

    reset =
      config
      |> put_in(["apps", "http", "servers", "still", "listen"], [":#{context_http_port(tags)}"])
      |> put_in(["apps", "http", "servers", "still", "routes"], [])
      |> put_in(
        ["apps", "http", "servers", "still", "automatic_https"],
        %{"disable" => true}
      )

    :ok = CaddyManager.load_config(reset)
    :ok
  end

  test "assigning a server to an app produces an ingress route in Caddy" do
    app =
      application_fixture(%{
        name: "ingress-app-#{System.unique_integer([:positive])}",
        type: :static_site,
        domain: "ingress-app.test",
        exec_command: nil,
        health_check: nil
      })

    server = server_fixture(%{host: "10.99.0.1"})
    {:ok, _assignment} = Applications.assign_server(Actor.system(), app, server)

    {:ok, reconciler} =
      IngressReconciler.start_link(
        name: :"reconciler_#{System.unique_integer([:positive])}",
        debounce_ms: 20,
        notifier: self()
      )

    on_exit(fn -> if Process.alive?(reconciler), do: GenServer.stop(reconciler) end)

    # Initial reconcile happens on boot — wait for it.
    assert_receive {:ingress_reconciled, :ok}, 2_000

    {:ok, caddy_config} = CaddyManager.get_config()
    routes = get_in(caddy_config, ["apps", "http", "servers", "still", "routes"])

    ingress_route = Enum.find(routes, &(&1["@id"] == "still_ingress_#{app.name}"))
    assert ingress_route, "expected an ingress route for #{app.name}"

    assert [%{"host" => ["ingress-app.test"]}] = ingress_route["match"]
    assert ingress_route["terminal"] == true

    [%{"handler" => "reverse_proxy", "upstreams" => upstreams}] = ingress_route["handle"]
    assert [%{"dial" => "10.99.0.1:8080"}] = upstreams
  end

  test "unassigning the last server drops the ingress route on the next reconcile" do
    app =
      application_fixture(%{
        name: "ingress-drop-#{System.unique_integer([:positive])}",
        type: :static_site,
        domain: "drop.test",
        exec_command: nil,
        health_check: nil
      })

    server = server_fixture(%{host: "10.99.0.2"})
    {:ok, assignment} = Applications.assign_server(Actor.system(), app, server)

    {:ok, reconciler} =
      IngressReconciler.start_link(
        name: :"reconciler_#{System.unique_integer([:positive])}",
        debounce_ms: 20,
        notifier: self()
      )

    on_exit(fn -> if Process.alive?(reconciler), do: GenServer.stop(reconciler) end)

    assert_receive {:ingress_reconciled, :ok}, 2_000

    {:ok, before_config} = CaddyManager.get_config()
    before_routes = get_in(before_config, ["apps", "http", "servers", "still", "routes"])
    assert Enum.any?(before_routes, &(&1["@id"] == "still_ingress_#{app.name}"))

    # Unassigning broadcasts :fleet_changed → debounced reconcile.
    {:ok, _} = Applications.unassign_server(Actor.system(), assignment)
    assert_receive {:ingress_reconciled, :ok}, 2_000

    {:ok, after_config} = CaddyManager.get_config()
    after_routes = get_in(after_config, ["apps", "http", "servers", "still", "routes"])
    refute Enum.any?(after_routes, &(&1["@id"] == "still_ingress_#{app.name}"))
  end

  test "updating an application's domain is reflected in the ingress route on the next reconcile" do
    app =
      application_fixture(%{
        name: "ingress-rename-#{System.unique_integer([:positive])}",
        type: :static_site,
        domain: "before.test",
        exec_command: nil,
        health_check: nil
      })

    server = server_fixture(%{host: "10.99.0.3"})
    {:ok, _} = Applications.assign_server(Actor.system(), app, server)

    {:ok, reconciler} =
      IngressReconciler.start_link(
        name: :"reconciler_#{System.unique_integer([:positive])}",
        debounce_ms: 20,
        notifier: self()
      )

    on_exit(fn -> if Process.alive?(reconciler), do: GenServer.stop(reconciler) end)

    assert_receive {:ingress_reconciled, :ok}, 2_000

    {:ok, _updated} =
      Applications.update_application(Actor.system(), app, %{domain: "after.test"})

    assert_receive {:ingress_reconciled, :ok}, 2_000

    {:ok, config} = CaddyManager.get_config()
    routes = get_in(config, ["apps", "http", "servers", "still", "routes"])
    route = Enum.find(routes, &(&1["@id"] == "still_ingress_#{app.name}"))

    assert [%{"host" => ["after.test"]}] = route["match"]
  end

  # The test context carries a Caddy instance — accept either the tags map
  # (when ExUnit hasn't yet resolved the on-exit fixture) or a bare map.
  defp context_http_port(%{caddy: %{http_port: port}}), do: port
  defp context_http_port(_), do: 80
end
