defmodule Still.Integration.CaddyBootstrapReconcileTest do
  @moduledoc """
  Exercises `Still.CaddyBootstrap.reconcile/1` against a real Caddy
  admin API. Covers every path that doesn't require privileged ports:
  the default tls_mode `:off` install (with and without a controller
  domain) is the realistic Profile 1 / Profile 2 shape that ships for
  operators running behind an external edge. The `tls_mode: :auto`
  path (listens on `:80`/`:443`) can't run here as a non-root test
  process, so that listener shape lives in the `rebuild/2` unit tests.
  """

  use Still.IntegrationCase

  alias Still.Agent.CaddyManager
  alias Still.CaddyBootstrap

  # Each test starts from a known-good still server so ordering doesn't
  # matter. We re-stamp `automatic_https.disable` every time because any
  # prior test could have gone through a reconcile path that produced a
  # still server without it (reconcile never emits automatic_https — it
  # only manages listen + routes — so in production the real Caddy keeps
  # auto_https on, which is what we want). Without this, a subsequent
  # test that seeds a host-matched route would trip Caddy into auto_https
  # and try to bind :80, failing as a non-root test process.
  setup %{caddy: caddy} do
    {:ok, config} = CaddyManager.get_config()

    reset =
      config
      |> put_in(
        ["apps", "http", "servers", "still"],
        %{
          "listen" => [":#{caddy.http_port}"],
          "routes" => [],
          "automatic_https" => %{"disable" => true}
        }
      )

    :ok = CaddyManager.load_config(reset)
    :ok
  end

  test "first install loads the initial config when no still server exists",
       %{caddy: caddy} do
    # Wipe the still server entirely so reconcile/1 exercises the
    # "server doesn't exist" branch.
    {:ok, config} = CaddyManager.get_config()
    wiped = update_in(config, ["apps", "http", "servers"], &Map.delete(&1, "still"))
    :ok = CaddyManager.load_config(wiped)

    assert :ok =
             CaddyBootstrap.reconcile(
               backend: "localhost:4000",
               http_port: caddy.http_port
             )

    {:ok, after_config} = CaddyManager.get_config()
    server = get_in(after_config, ["apps", "http", "servers", "still"])

    assert server["listen"] == [":#{caddy.http_port}"]
    assert [controller, catchall] = server["routes"]
    assert controller["@id"] == "still_controller"
    assert catchall["@id"] == "still_catchall"
  end

  test "reconcile preserves per-application routes across successive runs",
       %{caddy: caddy} do
    :ok =
      CaddyBootstrap.reconcile(
        backend: "localhost:4000",
        http_port: caddy.http_port
      )

    app_route = %{
      "@id" => "still_app_my-api",
      "match" => [%{"host" => ["api.test"]}],
      "handle" => [
        %{"handler" => "reverse_proxy", "upstreams" => [%{"dial" => "localhost:5000"}]}
      ],
      "terminal" => true
    }

    {:ok, config} = CaddyManager.get_config()

    seeded =
      update_in(
        config,
        ["apps", "http", "servers", "still", "routes"],
        fn routes -> routes ++ [app_route] end
      )

    :ok = CaddyManager.load_config(seeded)

    # Re-run reconcile with the same opts; the system routes should be
    # refreshed in place and the app route should still be there.
    assert :ok =
             CaddyBootstrap.reconcile(
               backend: "localhost:4000",
               http_port: caddy.http_port
             )

    {:ok, after_config} = CaddyManager.get_config()
    routes = get_in(after_config, ["apps", "http", "servers", "still", "routes"])

    ids = Enum.map(routes, & &1["@id"])
    assert ids == ["still_controller", "still_app_my-api", "still_catchall"]
  end

  test "reconcile updates the backend when http_port changes, preserving app routes",
       %{caddy: caddy} do
    :ok =
      CaddyBootstrap.reconcile(
        backend: "localhost:4000",
        http_port: caddy.http_port
      )

    app_route = %{
      "@id" => "still_app_site",
      "match" => [%{"host" => ["site.test"]}],
      "handle" => [%{"handler" => "file_server", "root" => "/srv"}],
      "terminal" => true
    }

    {:ok, config} = CaddyManager.get_config()

    seeded =
      update_in(
        config,
        ["apps", "http", "servers", "still", "routes"],
        fn routes -> routes ++ [app_route] end
      )

    :ok = CaddyManager.load_config(seeded)

    # New backend in the system routes — app route should survive.
    assert :ok =
             CaddyBootstrap.reconcile(
               backend: "localhost:4321",
               http_port: caddy.http_port
             )

    {:ok, after_config} = CaddyManager.get_config()

    [controller, preserved, catchall] =
      get_in(after_config, ["apps", "http", "servers", "still", "routes"])

    assert controller["@id"] == "still_controller"

    assert [%{"handler" => "reverse_proxy", "upstreams" => [%{"dial" => "localhost:4321"}]}] =
             controller["handle"]

    assert preserved["@id"] == "still_app_site"
    assert [%{"host" => ["site.test"]}] = preserved["match"]
    assert catchall["@id"] == "still_catchall"
  end

  test "reconcile builds the internal artifacts server with automatic_https disabled",
       %{caddy: caddy} do
    assert :ok =
             CaddyBootstrap.reconcile(
               backend: "localhost:4000",
               http_port: caddy.http_port
             )

    {:ok, config} = CaddyManager.get_config()
    internal = get_in(config, ["apps", "http", "servers", "still_internal"])

    # A real Caddy accepted the config and reflects it back: the internal
    # server stays off the TLS path so it can't pull in a :80 listener.
    assert internal["automatic_https"] == %{"disable" => true}
    assert [route] = internal["routes"]
    assert route["@id"] == "still_artifacts"
  end

  test "reconcile with controller_domain + tls_mode :off applies host matchers to system routes",
       %{caddy: caddy} do
    assert :ok =
             CaddyBootstrap.reconcile(
               backend: "localhost:4000",
               http_port: caddy.http_port,
               controller_domain: "still.tail-12ab.ts.net",
               tls_mode: :off
             )

    {:ok, config} = CaddyManager.get_config()
    server = get_in(config, ["apps", "http", "servers", "still"])

    # Listens on the plain http port — no privileged-port binding needed.
    assert server["listen"] == [":#{caddy.http_port}"]

    # The controller route carries the host matcher; the catch-all does not.
    controller = Enum.find(server["routes"], &(&1["@id"] == "still_controller"))
    [match] = controller["match"]
    assert match["host"] == ["still.tail-12ab.ts.net"]
    refute Map.has_key?(match, "path")

    catchall = Enum.find(server["routes"], &(&1["@id"] == "still_catchall"))
    refute Map.has_key?(catchall, "match")
  end

  test "reconcile falls back to fallback_host as the controller route's host matcher",
       %{caddy: caddy} do
    assert :ok =
             CaddyBootstrap.reconcile(
               backend: "localhost:4000",
               http_port: caddy.http_port,
               fallback_host: "10.0.0.5",
               tls_mode: :off
             )

    {:ok, config} = CaddyManager.get_config()

    controller =
      get_in(config, ["apps", "http", "servers", "still", "routes"])
      |> Enum.find(&(&1["@id"] == "still_controller"))

    assert [%{"host" => ["10.0.0.5"]}] = controller["match"]
  end

  test "the catch-all answers unmatched hosts with a 200 \"Still\" page over real HTTP",
       %{caddy: caddy} do
    assert :ok =
             CaddyBootstrap.reconcile(
               backend: "localhost:4000",
               http_port: caddy.http_port,
               controller_domain: "still.example.com",
               tls_mode: :off
             )

    # A request whose Host doesn't match the controller domain falls through
    # to the catch-all rather than reaching Phoenix or Caddy's empty default.
    {output, 0} =
      System.cmd("curl", [
        "-sS",
        "-H",
        "Host: stranger.example.com",
        "http://127.0.0.1:#{caddy.http_port}/"
      ])

    assert output == "Still"
  end
end
