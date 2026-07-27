defmodule Still.CaddyBootstrapTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Still.Agent.CaddyManager
  alias Still.CaddyBootstrap

  # Pull the "still" server out of a rebuilt config.
  defp still(config), do: config["apps"]["http"]["servers"]["still"]
  defp route_ids(server), do: Enum.map(server["routes"], & &1["@id"])

  defp base_opts(extra \\ []) do
    Keyword.merge([backend: "localhost:4000", http_port: 8080], extra)
  end

  describe "rebuild/2 — server provisioning into assorted config shapes" do
    test "adds the still server to a config that had none, preserving admin + other apps" do
      current = %{
        "admin" => %{"listen" => "localhost:2019"},
        "apps" => %{"http" => %{"servers" => %{"other" => %{"listen" => [":9000"]}}}}
      }

      rebuilt = CaddyBootstrap.rebuild(current, base_opts())

      assert rebuilt["admin"] == %{"listen" => "localhost:2019"}
      assert rebuilt["apps"]["http"]["servers"]["other"] == %{"listen" => [":9000"]}
      assert still(rebuilt)["listen"] == [":8080"]
      assert route_ids(still(rebuilt)) == ["still_controller", "still_catchall"]
    end

    test "tolerates a completely empty config" do
      rebuilt = CaddyBootstrap.rebuild(%{}, base_opts())
      assert still(rebuilt)["listen"] == [":8080"]
      assert route_ids(still(rebuilt)) == ["still_controller", "still_catchall"]
    end

    test "tolerates a config missing the apps key entirely" do
      rebuilt = CaddyBootstrap.rebuild(%{"admin" => %{}}, base_opts())
      assert still(rebuilt)["listen"] == [":8080"]
    end

    test "tolerates apps present but http/servers missing" do
      rebuilt = CaddyBootstrap.rebuild(%{"apps" => %{}}, base_opts())
      assert still(rebuilt)["listen"] == [":8080"]
    end

    test "preserves unrelated fields on an existing still server" do
      current = %{
        "apps" => %{
          "http" => %{
            "servers" => %{
              "still" => %{
                "routes" => [],
                "read_timeout" => "30s",
                "tls_connection_policies" => [%{"alpn" => ["h2"]}]
              }
            }
          }
        }
      }

      server = still(CaddyBootstrap.rebuild(current, base_opts()))
      assert server["read_timeout"] == "30s"
      assert server["tls_connection_policies"] == [%{"alpn" => ["h2"]}]
    end
  end

  describe "rebuild/2 — default welcome-page eviction" do
    # The OS Caddy package's default Caddyfile adapts to this: a file_server
    # rooted at the package web root, on :80, named `srv0`.
    defp welcome_server(listen) do
      %{
        "listen" => listen,
        "routes" => [
          %{
            "handle" => [
              %{"handler" => "vars", "root" => "/usr/share/caddy"},
              %{"handler" => "file_server"}
            ]
          }
        ]
      }
    end

    defp servers(config), do: config["apps"]["http"]["servers"]

    defp with_servers(servers) do
      %{"apps" => %{"http" => %{"servers" => servers}}}
    end

    test "evicts the default welcome server when the still server takes its port (:auto)" do
      current = with_servers(%{"srv0" => welcome_server([":80"])})
      opts = base_opts(controller_domain: "still.example.com", tls_mode: :auto)

      {rebuilt, log} = with_log(fn -> servers(CaddyBootstrap.rebuild(current, opts)) end)

      refute Map.has_key?(rebuilt, "srv0")
      assert rebuilt["still"]["listen"] == [":80", ":443"]
      assert Map.has_key?(rebuilt, "still_internal")
      assert log =~ ~s(removed Caddy's default welcome-page server "srv0")
      assert log =~ "(80, 443, 9090)"
    end

    test "keeps the welcome server under :off — the still server is on :8080, no collision" do
      current = with_servers(%{"srv0" => welcome_server([":80"])})

      rebuilt = servers(CaddyBootstrap.rebuild(current, base_opts(tls_mode: :off)))

      assert rebuilt["srv0"] == welcome_server([":80"])
      assert rebuilt["still"]["listen"] == [":8080"]
    end

    test "keeps a welcome-shaped server that doesn't collide with a still port" do
      current = with_servers(%{"srv0" => welcome_server([":8081"])})
      opts = base_opts(controller_domain: "still.example.com", tls_mode: :auto)

      rebuilt = servers(CaddyBootstrap.rebuild(current, opts))

      assert rebuilt["srv0"] == welcome_server([":8081"])
    end

    test "leaves an operator-configured server on the same port for Caddy to reject" do
      # Not the default welcome page — an operator's own :80 server. We don't
      # silently delete it; Caddy rejects the load and the operator resolves it.
      operator = %{
        "listen" => [":80"],
        "routes" => [
          %{"handle" => [%{"handler" => "static_response", "body" => "mine"}]}
        ]
      }

      current = with_servers(%{"edge" => operator})
      opts = base_opts(controller_domain: "still.example.com", tls_mode: :auto)

      rebuilt = servers(CaddyBootstrap.rebuild(current, opts))

      assert rebuilt["edge"] == operator
    end

    test "only the colliding welcome server goes; a non-colliding foreign server stays" do
      current =
        with_servers(%{
          "srv0" => welcome_server([":80"]),
          "other" => %{"listen" => [":9000"]}
        })

      opts = base_opts(controller_domain: "still.example.com", tls_mode: :auto)
      {rebuilt, log} = with_log(fn -> servers(CaddyBootstrap.rebuild(current, opts)) end)

      refute Map.has_key?(rebuilt, "srv0")
      assert rebuilt["other"] == %{"listen" => [":9000"]}
      # only srv0 is evicted — "other" is never logged as removed
      assert log =~ ~s(removed Caddy's default welcome-page server "srv0")
      refute log =~ "other"
    end
  end

  describe "rebuild/2 — controller host resolution" do
    test "uses controller_domain as the host matcher when set" do
      server =
        still(CaddyBootstrap.rebuild(%{}, base_opts(controller_domain: "still.example.com")))

      assert [%{"host" => ["still.example.com"]}] = controller_route(server)["match"]
    end

    test "falls back to fallback_host when controller_domain is nil" do
      server = still(CaddyBootstrap.rebuild(%{}, base_opts(fallback_host: "10.0.0.5")))
      assert [%{"host" => ["10.0.0.5"]}] = controller_route(server)["match"]
    end

    test "falls back to fallback_host when controller_domain is an empty string" do
      opts = base_opts(controller_domain: "", fallback_host: "10.0.0.5")
      server = still(CaddyBootstrap.rebuild(%{}, opts))
      assert [%{"host" => ["10.0.0.5"]}] = controller_route(server)["match"]
    end

    test "controller_domain wins over fallback_host when both are set" do
      opts = base_opts(controller_domain: "still.example.com", fallback_host: "10.0.0.5")
      server = still(CaddyBootstrap.rebuild(%{}, opts))
      assert [%{"host" => ["still.example.com"]}] = controller_route(server)["match"]
    end

    test "no host matcher when both domain and fallback are absent (match-all controller route)" do
      server = still(CaddyBootstrap.rebuild(%{}, base_opts()))
      refute Map.has_key?(controller_route(server), "match")
    end

    test "treats a blank fallback_host the same as an absent one" do
      server =
        still(CaddyBootstrap.rebuild(%{}, base_opts(controller_domain: "", fallback_host: "")))

      refute Map.has_key?(controller_route(server), "match")
    end
  end

  describe "rebuild/2 — controller route shape" do
    setup do
      server =
        still(CaddyBootstrap.rebuild(%{}, base_opts(controller_domain: "still.example.com")))

      %{route: controller_route(server)}
    end

    test "is terminal so evaluation stops once it matches", %{route: route} do
      assert route["terminal"] == true
    end

    test "matches the whole host with no path matcher (Phoenix owns all paths)", %{route: route} do
      [match] = route["match"]
      assert match["host"] == ["still.example.com"]
      refute Map.has_key?(match, "path")
    end

    test "reverse_proxies to the backend", %{route: route} do
      assert [%{"handler" => "reverse_proxy", "upstreams" => [%{"dial" => "localhost:4000"}]}] =
               route["handle"]
    end

    # Still's own dashboard/API traffic stays out of application traces —
    # Still.Caddy.TracingTest pins that it isn't traced with tracing enabled.
    test "carries no tracing handler", %{route: route} do
      assert Enum.map(route["handle"], & &1["handler"]) == ["reverse_proxy"]
    end
  end

  describe "rebuild/2 — catch-all route shape" do
    setup do
      server =
        still(CaddyBootstrap.rebuild(%{}, base_opts(controller_domain: "still.example.com")))

      %{route: catchall(server)}
    end

    test "answers a 200 'Still' static page", %{route: route} do
      assert [%{"handler" => "static_response", "status_code" => 200, "body" => "Still"}] =
               route["handle"]
    end

    test "has no matcher so it catches every unmatched host", %{route: route} do
      refute Map.has_key?(route, "match")
    end

    test "is terminal", %{route: route} do
      assert route["terminal"] == true
    end

    test "is always the last route", %{route: route} do
      _ = route
      server = still(CaddyBootstrap.rebuild(%{}, base_opts()))
      assert List.last(server["routes"])["@id"] == "still_catchall"
    end
  end

  describe "rebuild/2 — listen array" do
    test "defaults to the plain http_port (tls_mode :off)" do
      assert still(CaddyBootstrap.rebuild(%{}, base_opts()))["listen"] == [":8080"]
    end

    test "tls_mode :auto listens on :80 and :443" do
      opts = base_opts(controller_domain: "still.example.com", tls_mode: :auto)
      assert still(CaddyBootstrap.rebuild(%{}, opts))["listen"] == [":80", ":443"]
    end

    test "domain does not change the listener under :off" do
      opts = base_opts(controller_domain: "still.example.com", tls_mode: :off)
      assert still(CaddyBootstrap.rebuild(%{}, opts))["listen"] == [":8080"]
    end

    test "honors a non-default http_port" do
      assert still(CaddyBootstrap.rebuild(%{}, base_opts(http_port: 9999)))["listen"] == [":9999"]
    end
  end

  describe "rebuild/2 — automatic_https" do
    test ":off disables automatic HTTPS so an external edge owns TLS" do
      server = still(CaddyBootstrap.rebuild(%{}, base_opts(tls_mode: :off)))
      assert server["automatic_https"] == %{"disable" => true}
    end

    test ":auto leaves automatic_https unset so Caddy manages certs" do
      opts = base_opts(controller_domain: "still.example.com", tls_mode: :auto)
      refute Map.has_key?(still(CaddyBootstrap.rebuild(%{}, opts)), "automatic_https")
    end

    test ":auto clears a stale disable left by a prior :off run" do
      current = %{
        "apps" => %{
          "http" => %{
            "servers" => %{
              "still" => %{"routes" => [], "automatic_https" => %{"disable" => true}}
            }
          }
        }
      }

      opts = base_opts(controller_domain: "still.example.com", tls_mode: :auto)
      refute Map.has_key?(still(CaddyBootstrap.rebuild(current, opts)), "automatic_https")
    end
  end

  describe "rebuild/2 — metrics" do
    test "enables app-level per-host metrics and clears the deprecated per-server field" do
      current = %{
        "apps" => %{
          "http" => %{
            "servers" => %{"still" => %{"routes" => [], "metrics" => %{"per_host" => true}}}
          }
        }
      }

      rebuilt = CaddyBootstrap.rebuild(current, base_opts())
      assert rebuilt["apps"]["http"]["metrics"] == %{"per_host" => true}
      refute Map.has_key?(still(rebuilt), "metrics")
    end
  end

  describe "rebuild/2 — preserving and ordering app routes" do
    test "controller first, preserved app routes in the middle, catch-all last" do
      app_a = app_route("still_app_a", "a.test")
      app_b = app_route("still_ingress_b", "b.test")
      current = still_with_routes([app_a, app_b])

      routes = still(CaddyBootstrap.rebuild(current, base_opts()))["routes"]

      assert route_ids_of(routes) == [
               "still_controller",
               "still_app_a",
               "still_ingress_b",
               "still_catchall"
             ]
    end

    test "replaces a stale controller route rather than duplicating it" do
      stale = %{
        "@id" => "still_controller",
        "match" => [%{"host" => ["old"]}],
        "handle" => [%{"handler" => "reverse_proxy", "upstreams" => [%{"dial" => "old:9999"}]}]
      }

      current = still_with_routes([stale, app_route("still_app_a", "a.test")])

      routes =
        still(CaddyBootstrap.rebuild(current, base_opts(controller_domain: "new.test")))["routes"]

      assert Enum.count(routes, &(&1["@id"] == "still_controller")) == 1
      controller = Enum.find(routes, &(&1["@id"] == "still_controller"))
      assert [%{"host" => ["new.test"]}] = controller["match"]

      assert [%{"upstreams" => [%{"dial" => "localhost:4000"}]}] = controller["handle"]
    end

    test "collapses a stale catch-all sitting in the middle to a single one at the end" do
      stale_catchall = %{
        "@id" => "still_catchall",
        "handle" => [%{"handler" => "static_response", "status_code" => 200, "body" => "old"}]
      }

      current = still_with_routes([stale_catchall, app_route("still_app_a", "a.test")])
      routes = still(CaddyBootstrap.rebuild(current, base_opts()))["routes"]

      assert Enum.count(routes, &(&1["@id"] == "still_catchall")) == 1
      assert List.last(routes)["@id"] == "still_catchall"
      # the fresh catch-all, not the stale "old" body
      assert [%{"body" => "Still"}] = List.last(routes)["handle"]
    end

    test "preserves an operator-authored route that has no @id" do
      legacy = %{
        "match" => [%{"path" => ["/legacy/*"]}],
        "handle" => [%{"handler" => "static_response", "body" => "legacy"}]
      }

      current = still_with_routes([legacy])
      routes = still(CaddyBootstrap.rebuild(current, base_opts()))["routes"]

      assert legacy in routes
      assert List.first(routes)["@id"] == "still_controller"
      assert List.last(routes)["@id"] == "still_catchall"
    end

    test "is idempotent — rebuilding an already-rebuilt config is a no-op on the route set" do
      current = still_with_routes([app_route("still_app_a", "a.test")])
      once = CaddyBootstrap.rebuild(current, base_opts(controller_domain: "still.example.com"))
      twice = CaddyBootstrap.rebuild(once, base_opts(controller_domain: "still.example.com"))

      assert still(once)["routes"] == still(twice)["routes"]
    end
  end

  describe "rebuild/2 — internal artifacts server" do
    test "listens on the default internal port and disables automatic HTTPS" do
      internal =
        CaddyBootstrap.rebuild(%{}, base_opts(tls_mode: :off))
        |> get_in(["apps", "http", "servers", "still_internal"])

      assert internal["listen"] == [":9090"]
      assert internal["automatic_https"] == %{"disable" => true}
    end

    test "stays TLS-disabled even under tls_mode :auto" do
      opts = base_opts(controller_domain: "still.example.com", tls_mode: :auto)

      internal =
        CaddyBootstrap.rebuild(%{}, opts)
        |> get_in(["apps", "http", "servers", "still_internal"])

      assert internal["automatic_https"] == %{"disable" => true}
    end

    test "honors a custom internal_port and artifacts_dir" do
      opts = base_opts(internal_port: 9999, artifacts_dir: "/srv/artifacts")

      internal =
        CaddyBootstrap.rebuild(%{}, opts)
        |> get_in(["apps", "http", "servers", "still_internal"])

      assert internal["listen"] == [":9999"]
      [route] = internal["routes"]
      assert route["@id"] == "still_artifacts"
      assert [%{"path" => ["/artifacts/*"]}] = route["match"]
      assert Enum.any?(route["handle"], &(&1["handler"] == "file_server"))
      assert Enum.any?(route["handle"], &(&1["root"] == "/srv/artifacts"))
    end
  end

  describe "with_catchall_last/1" do
    test "appends a catch-all to an empty list" do
      assert [c] = CaddyBootstrap.with_catchall_last([])
      assert c["@id"] == "still_catchall"
    end

    test "appends a catch-all to a list that lacks one" do
      routes = [app_route("still_app_a", "a.test")]
      result = CaddyBootstrap.with_catchall_last(routes)
      assert route_ids_of(result) == ["still_app_a", "still_catchall"]
    end

    test "moves an existing catch-all to the end, preserving other order" do
      routes = [
        CaddyBootstrap.catchall_route(),
        app_route("still_app_a", "a.test"),
        app_route("still_app_b", "b.test")
      ]

      result = CaddyBootstrap.with_catchall_last(routes)
      assert route_ids_of(result) == ["still_app_a", "still_app_b", "still_catchall"]
    end

    test "collapses multiple catch-alls into exactly one at the end" do
      routes = [
        CaddyBootstrap.catchall_route(),
        app_route("still_app_a", "a.test"),
        CaddyBootstrap.catchall_route()
      ]

      result = CaddyBootstrap.with_catchall_last(routes)
      assert Enum.count(result, &CaddyBootstrap.catchall_route?/1) == 1
      assert List.last(result)["@id"] == "still_catchall"
    end

    test "is idempotent" do
      routes = [app_route("still_app_a", "a.test")]
      once = CaddyBootstrap.with_catchall_last(routes)
      assert once == CaddyBootstrap.with_catchall_last(once)
    end
  end

  describe "catchall_route?/1" do
    test "true only for the catch-all route" do
      assert CaddyBootstrap.catchall_route?(CaddyBootstrap.catchall_route())
      refute CaddyBootstrap.catchall_route?(app_route("still_app_a", "a.test"))
      refute CaddyBootstrap.catchall_route?(%{"@id" => "still_controller"})
      refute CaddyBootstrap.catchall_route?(%{"handle" => []})
    end
  end

  describe "system_route_list/1" do
    test "returns a single host-scoped controller route" do
      assert [route] =
               CaddyBootstrap.system_route_list(
                 backend: "localhost:4000",
                 controller_domain: "still.example.com"
               )

      assert route["@id"] == "still_controller"
      assert [%{"host" => ["still.example.com"]}] = route["match"]
      refute route["match"] |> hd() |> Map.has_key?("path")
    end

    test "uses the fallback host when no domain is given" do
      [route] =
        CaddyBootstrap.system_route_list(backend: "localhost:4000", fallback_host: "10.0.0.5")

      assert [%{"host" => ["10.0.0.5"]}] = route["match"]
    end

    test "omits the host matcher when neither domain nor fallback is set" do
      [route] = CaddyBootstrap.system_route_list(backend: "localhost:4000")
      refute Map.has_key?(route, "match")
    end

    test "returns no routes in agent mode" do
      assert CaddyBootstrap.system_route_list(mode: :agent) == []
    end
  end

  describe "rebuild/2 — agent mode" do
    test "writes no controller route, only app routes and the catch-all" do
      current = still_with_routes([app_route("still_app_a", "a.test")])
      server = still(CaddyBootstrap.rebuild(current, base_opts(mode: :agent)))
      assert route_ids(server) == ["still_app_a", "still_catchall"]
    end

    test "drops a stale controller route from an earlier install" do
      current =
        still_with_routes([
          %{
            "@id" => "still_controller",
            "match" => [%{"host" => ["10.0.0.9"]}],
            "handle" => [%{"handler" => "reverse_proxy"}]
          },
          app_route("still_app_a", "a.test")
        ])

      server = still(CaddyBootstrap.rebuild(current, base_opts(mode: :agent)))
      assert route_ids(server) == ["still_app_a", "still_catchall"]
    end
  end

  describe "rebuild/2 — trusted_proxies" do
    defp still_with_trusted(ranges) do
      %{
        "apps" => %{
          "http" => %{
            "servers" => %{
              "still" => %{"trusted_proxies" => %{"source" => "static", "ranges" => ranges}}
            }
          }
        }
      }
    end

    test "sets a static trusted_proxies module when given" do
      server = still(CaddyBootstrap.rebuild(%{}, base_opts(trusted_proxies: ["10.0.0.1/32"])))
      assert server["trusted_proxies"] == %{"source" => "static", "ranges" => ["10.0.0.1/32"]}
    end

    test "leaves an existing trusted_proxies alone when the option is absent" do
      server = still(CaddyBootstrap.rebuild(still_with_trusted(["10.9.9.9/32"]), base_opts()))
      assert server["trusted_proxies"] == %{"source" => "static", "ranges" => ["10.9.9.9/32"]}
    end

    test "removes trusted_proxies when given an empty list" do
      current = still_with_trusted(["10.9.9.9/32"])
      server = still(CaddyBootstrap.rebuild(current, base_opts(trusted_proxies: [])))
      refute Map.has_key?(server, "trusted_proxies")
    end
  end

  describe "listen/1" do
    test "defaults to tls_mode :off — single http_port entry" do
      assert CaddyBootstrap.listen(http_port: 8080) == [":8080"]
    end

    test "tls_mode :off returns the plain http_port regardless of domain" do
      assert CaddyBootstrap.listen(http_port: 8080, controller_domain: "x.test", tls_mode: :off) ==
               [":8080"]
    end

    test "tls_mode :auto listens on :80 and :443" do
      assert CaddyBootstrap.listen(http_port: 8080, tls_mode: :auto) == [":80", ":443"]
    end
  end

  describe "reconcile/1" do
    test "fetches the current config, rebuilds, and posts the new config to Caddy" do
      current = %{
        "admin" => %{"listen" => "localhost:2019"},
        "apps" => %{"http" => %{"servers" => %{}}}
      }

      test_pid = self()

      Req.Test.stub(CaddyManager, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/config/"} ->
            Req.Test.json(conn, current)

          {"POST", "/load"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:loaded, Jason.decode!(body)})
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = CaddyBootstrap.reconcile(base_opts(controller_domain: "still.example.com"))
      assert_received {:loaded, loaded}

      server = loaded["apps"]["http"]["servers"]["still"]
      assert server["listen"] == [":8080"]
      assert route_ids(server) == ["still_controller", "still_catchall"]
      assert loaded["admin"] == %{"listen" => "localhost:2019"}
    end

    @tag :capture_log
    test "returns a tagged error when Caddy's get_config fails" do
      Req.Test.stub(CaddyManager, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
      end)

      assert {:error, {:caddy_status, 500, _}} = CaddyBootstrap.reconcile(base_opts())
    end

    @tag :capture_log
    test "returns a tagged error when Caddy rejects the new config on load" do
      Req.Test.stub(CaddyManager, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/config/"} ->
            Req.Test.json(conn, %{"apps" => %{"http" => %{"servers" => %{}}}})

          {"POST", "/load"} ->
            conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "nope"})
        end
      end)

      assert {:error, {:caddy_status, 400, _}} = CaddyBootstrap.reconcile(base_opts())
    end
  end

  # --- helpers ---

  defp controller_route(server),
    do: Enum.find(server["routes"], &(&1["@id"] == "still_controller"))

  defp catchall(server), do: Enum.find(server["routes"], &(&1["@id"] == "still_catchall"))
  defp route_ids_of(routes), do: Enum.map(routes, & &1["@id"])

  defp app_route(id, host) do
    %{
      "@id" => id,
      "match" => [%{"host" => [host]}],
      "handle" => [%{"handler" => "reverse_proxy", "upstreams" => [%{"dial" => "#{host}:8080"}]}],
      "terminal" => true
    }
  end

  defp still_with_routes(routes) do
    %{
      "apps" => %{
        "http" => %{"servers" => %{"still" => %{"listen" => [":8080"], "routes" => routes}}}
      }
    }
  end
end
