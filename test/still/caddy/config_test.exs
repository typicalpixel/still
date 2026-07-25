defmodule Still.Caddy.ConfigTest do
  use ExUnit.Case, async: true

  alias Still.Caddy.Config

  describe "route/1" do
    test "builds a route with id, match, handle, and terminal" do
      route =
        Config.route(
          id: "still_app_api",
          match: [%{"host" => ["api.test"]}],
          handle: [%{"handler" => "reverse_proxy"}],
          terminal: true
        )

      assert route == %{
               "@id" => "still_app_api",
               "match" => [%{"host" => ["api.test"]}],
               "handle" => [%{"handler" => "reverse_proxy"}],
               "terminal" => true
             }
    end

    test "omits @id when not given (for subroute inner routes)" do
      route =
        Config.route(
          match: [%{"path" => ["/*"]}],
          handle: [%{"handler" => "file_server"}]
        )

      refute Map.has_key?(route, "@id")
    end

    test "omits match when not given (for catch-all inner routes)" do
      route = Config.route(handle: [%{"handler" => "file_server"}])
      refute Map.has_key?(route, "match")
      refute Map.has_key?(route, "@id")
      refute Map.has_key?(route, "terminal")
    end

    test "omits terminal when false (the default)" do
      route =
        Config.route(
          id: "x",
          match: [%{"path" => ["/*"]}],
          handle: [%{"handler" => "file_server"}]
        )

      refute Map.has_key?(route, "terminal")
    end

    test "raises without :handle" do
      assert_raise KeyError, fn -> Config.route(id: "x") end
    end

    test "raises on empty :handle" do
      assert_raise ArgumentError, ~r/non-empty list/, fn ->
        Config.route(id: "x", handle: [])
      end
    end

    test "raises on non-list :match" do
      assert_raise ArgumentError, ~r/:match/, fn ->
        Config.route(id: "x", match: "not a list", handle: [%{"h" => "h"}])
      end
    end

    test "raises on non-string :id" do
      assert_raise ArgumentError, ~r/:id/, fn ->
        Config.route(id: :atom, handle: [%{"h" => "h"}])
      end
    end
  end

  describe "match/1" do
    test "host only" do
      assert Config.match(host: ["api.test"]) == %{"host" => ["api.test"]}
    end

    test "path only" do
      assert Config.match(path: ["/api/*"]) == %{"path" => ["/api/*"]}
    end

    test "host and path combined" do
      assert Config.match(host: ["api.test"], path: ["/v1/*"]) == %{
               "host" => ["api.test"],
               "path" => ["/v1/*"]
             }
    end

    test "raises when neither host nor path is given" do
      assert_raise ArgumentError, ~r/at least one of :host or :path/, fn ->
        Config.match([])
      end
    end

    test "raises on host not a list" do
      assert_raise ArgumentError, ~r/:host/, fn -> Config.match(host: "api.test") end
    end

    test "raises on empty host list" do
      assert_raise ArgumentError, ~r/:host/, fn -> Config.match(host: []) end
    end

    test "raises on host list with empty strings" do
      assert_raise ArgumentError, ~r/:host/, fn -> Config.match(host: [""]) end
    end

    test "raises on path not a list" do
      assert_raise ArgumentError, ~r/:path/, fn -> Config.match(path: "/api") end
    end
  end

  describe "reverse_proxy/1" do
    test "builds the handler with a single upstream via :dial" do
      assert Config.reverse_proxy(dial: "localhost:4000") == %{
               "handler" => "reverse_proxy",
               "upstreams" => [%{"dial" => "localhost:4000"}]
             }
    end

    test "builds the handler with multiple upstreams via :dials" do
      assert Config.reverse_proxy(dials: ["10.0.0.3:80", "10.0.0.4:80"]) == %{
               "handler" => "reverse_proxy",
               "upstreams" => [
                 %{"dial" => "10.0.0.3:80"},
                 %{"dial" => "10.0.0.4:80"}
               ]
             }
    end

    test "attaches an active health check when given" do
      handler =
        Config.reverse_proxy(
          dial: "localhost:4000",
          health_check: %{path: "/health", interval_ms: 10_000, deadline_ms: 5_000}
        )

      assert handler["health_checks"] == %{
               "active" => %{
                 "uri" => "/health",
                 "interval" => "10000ms",
                 "timeout" => "5000ms"
               }
             }
    end

    test "omits health_checks when not given" do
      refute Map.has_key?(Config.reverse_proxy(dial: "localhost:4000"), "health_checks")
    end

    test "rejects empty :dial" do
      assert_raise ArgumentError, fn -> Config.reverse_proxy(dial: "") end
    end

    test "rejects empty :dials list" do
      assert_raise ArgumentError, fn -> Config.reverse_proxy(dials: []) end
    end

    test "rejects :dials containing an empty string" do
      assert_raise ArgumentError, fn -> Config.reverse_proxy(dials: ["10.0.0.3:80", ""]) end
    end

    test "rejects both :dial and :dials given" do
      assert_raise ArgumentError, fn ->
        Config.reverse_proxy(dial: "a:80", dials: ["b:80"])
      end
    end

    test "rejects neither :dial nor :dials" do
      assert_raise ArgumentError, fn -> Config.reverse_proxy([]) end
    end

    test "emits load_balancing.selection_policy when :lb_policy is given" do
      handler =
        Config.reverse_proxy(dials: ["10.0.0.3:80", "10.0.0.4:80"], lb_policy: :ip_hash)

      assert handler["load_balancing"] == %{
               "selection_policy" => %{"policy" => "ip_hash"}
             }
    end

    test "omits load_balancing when :lb_policy is not given" do
      refute Map.has_key?(Config.reverse_proxy(dial: "localhost:4000"), "load_balancing")
    end

    test "rejects unknown :lb_policy values" do
      assert_raise ArgumentError, fn ->
        Config.reverse_proxy(dial: "localhost:4000", lb_policy: :bogus)
      end
    end
  end

  describe "tracing/1" do
    test "returns the handler map with the given span name" do
      assert Config.tracing(span: "my-api") == %{"handler" => "tracing", "span" => "my-api"}
    end

    test "rejects a blank span" do
      assert_raise ArgumentError, fn -> Config.tracing(span: "") end
    end

    test "rejects a non-binary span" do
      assert_raise ArgumentError, fn -> Config.tracing(span: :api) end
    end

    test "requires :span" do
      assert_raise KeyError, fn -> Config.tracing(span_attributes: %{"http.route" => "x"}) end
    end

    test "emits span_attributes when given" do
      assert Config.tracing(span: "my-api", span_attributes: %{"http.route" => "my-api"}) ==
               %{
                 "handler" => "tracing",
                 "span" => "my-api",
                 "span_attributes" => %{"http.route" => "my-api"}
               }
    end

    test "accepts options in any order" do
      assert Config.tracing(span_attributes: %{"http.route" => "my-api"}, span: "my-api") ==
               Config.tracing(span: "my-api", span_attributes: %{"http.route" => "my-api"})
    end

    test "rejects an empty span_attributes map" do
      assert_raise ArgumentError, fn ->
        Config.tracing(span: "my-api", span_attributes: %{})
      end
    end

    test "rejects non-string span_attributes entries" do
      assert_raise ArgumentError, fn ->
        Config.tracing(span: "my-api", span_attributes: %{"http.route" => 42})
      end

      assert_raise ArgumentError, fn ->
        Config.tracing(span: "my-api", span_attributes: %{route: "my-api"})
      end
    end

    test "rejects span_attributes values containing Caddy placeholder braces" do
      assert_raise ArgumentError, fn ->
        Config.tracing(span: "my-api", span_attributes: %{"http.route" => "{http.request.uri}"})
      end
    end
  end

  describe "file_server/0, vars/1, rewrite/1, subroute/1" do
    test "file_server returns the bare handler map" do
      assert Config.file_server() == %{"handler" => "file_server"}
    end

    test "vars sets the root" do
      assert Config.vars(root: "/srv/app") == %{"handler" => "vars", "root" => "/srv/app"}
    end

    test "rewrite sets the uri" do
      assert Config.rewrite(uri: "/index.html") == %{
               "handler" => "rewrite",
               "uri" => "/index.html"
             }
    end

    test "subroute wraps a non-empty route list" do
      inner = %{"handle" => [%{"handler" => "file_server"}]}
      assert Config.subroute(routes: [inner]) == %{"handler" => "subroute", "routes" => [inner]}
    end

    test "subroute rejects empty route list" do
      assert_raise FunctionClauseError, fn -> Config.subroute(routes: []) end
    end
  end

  describe "static_response/1" do
    test "defaults to a 200 with an empty body" do
      assert Config.static_response() == %{
               "handler" => "static_response",
               "status_code" => 200,
               "body" => ""
             }
    end

    test "sets a custom status and body" do
      assert Config.static_response(status: 503, body: "Down for maintenance") == %{
               "handler" => "static_response",
               "status_code" => 503,
               "body" => "Down for maintenance"
             }
    end

    test "rejects a non-integer status" do
      assert_raise ArgumentError, ~r/:status/, fn -> Config.static_response(status: "200") end
    end

    test "rejects an out-of-range status" do
      assert_raise ArgumentError, ~r/:status/, fn -> Config.static_response(status: 42) end
    end

    test "rejects a non-string body" do
      assert_raise ArgumentError, ~r/:body/, fn -> Config.static_response(body: :nope) end
    end
  end

  describe "maintenance_response/1" do
    test "builds a 503 static_response with the operator's message" do
      assert Config.maintenance_response("Back at 5pm UTC") == %{
               "handler" => "static_response",
               "status_code" => 503,
               "body" => "Back at 5pm UTC"
             }
    end

    test "falls back to a default body when the message is nil" do
      assert %{"status_code" => 503, "body" => body} = Config.maintenance_response()
      assert body =~ "maintenance"
    end

    test "falls back to a default body when the message is blank" do
      assert %{"body" => body} = Config.maintenance_response("")
      assert body =~ "maintenance"
    end
  end

  describe "encode/0" do
    test "enables zstd and gzip with a preference order" do
      assert Config.encode() == %{
               "handler" => "encode",
               "encodings" => %{"zstd" => %{}, "gzip" => %{}},
               "prefer" => ["zstd", "gzip"]
             }
    end
  end

  describe "response_header/2" do
    test "sets a single response header, overwriting existing values" do
      assert Config.response_header("Cache-Control", "no-cache") == %{
               "handler" => "headers",
               "response" => %{"set" => %{"Cache-Control" => ["no-cache"]}}
             }
    end

    test "rejects a blank name or value" do
      assert_raise FunctionClauseError, fn -> Config.response_header("", "no-cache") end
      assert_raise FunctionClauseError, fn -> Config.response_header("Cache-Control", "") end
    end
  end

  describe "static_site_handle/1" do
    test "produces a subroute: vars+encode → try_files rewrite → cache headers → file_server" do
      [handle] = Config.static_site_handle(root: "/var/apps/site/current_blue")

      assert handle["handler"] == "subroute"
      routes = handle["routes"]
      assert length(routes) == 5

      [first, rewrite, assets, shell, last] = routes

      # First inner route: vars sets the root, encode compresses the response
      assert first == %{
               "handle" => [
                 %{"handler" => "vars", "root" => "/var/apps/site/current_blue"},
                 Config.encode()
               ]
             }

      # try_files matcher + rewrite to the matched file
      assert [
               %{"file" => %{"try_files" => ["{http.request.uri.path}", "/index.html"]}}
             ] = rewrite["match"]

      assert [%{"handler" => "rewrite", "uri" => "{http.matchers.file.relative}"}] =
               rewrite["handle"]

      # Content-hashed assets are cached forever and immutable
      assert assets == %{
               "match" => [%{"path" => ["/assets/*"]}],
               "handle" => [
                 Config.response_header("Cache-Control", "public, max-age=31536000, immutable")
               ]
             }

      # Everything else — the unhashed shell, incl. the deep-link fallback —
      # is no-cache. The `not` matcher keeps the two rules mutually exclusive.
      assert shell == %{
               "match" => [%{"not" => [%{"path" => ["/assets/*"]}]}],
               "handle" => [Config.response_header("Cache-Control", "no-cache")]
             }

      # Catch-all file_server serves whatever the rewrite produced
      assert last == %{"handle" => [%{"handler" => "file_server"}]}
    end

    test "cache rules run after the try_files rewrite so they match the final path" do
      [%{"routes" => routes}] = Config.static_site_handle(root: "/var/apps/site/current_blue")

      rewrite_idx =
        Enum.find_index(routes, &match?(%{"handle" => [%{"handler" => "rewrite"}]}, &1))

      header_idx =
        Enum.find_index(routes, fn route ->
          match?([%{"handler" => "headers"}], route["handle"])
        end)

      assert rewrite_idx < header_idx
    end

    test "rejects an empty root" do
      assert_raise FunctionClauseError, fn -> Config.static_site_handle(root: "") end
    end
  end
end
