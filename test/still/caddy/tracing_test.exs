defmodule Still.Caddy.TracingTest do
  # Flips the global :caddy_tracing knob, so it can't run alongside the async
  # route-writer tests that assert the default-off JSON.
  use ExUnit.Case, async: false

  alias Still.Agent.DeploymentManager
  alias Still.Applications.Application, as: App
  alias Still.Applications.HealthCheck
  alias Still.Caddy.Tracing
  alias Still.CaddyBootstrap
  alias Still.Fleet.Server
  alias Still.Ingress

  setup context do
    if enabled = context[:tracing] do
      original = Elixir.Application.get_env(:still, :caddy_tracing)
      Elixir.Application.put_env(:still, :caddy_tracing, enabled)
      on_exit(fn -> Elixir.Application.put_env(:still, :caddy_tracing, original) end)
    end

    :ok
  end

  defp app_entry(name, attrs \\ %{}) do
    app =
      struct(App, %{
        id: Ecto.UUID.generate(),
        name: name,
        type: :elixir_release,
        domain: "#{name}.example.com",
        health_check: %HealthCheck{path: "/health", interval_ms: 5_000, deadline_ms: 3_000}
      })

    %{
      application: struct(app, attrs),
      servers: [%Server{id: Ecto.UUID.generate(), name: "agent-1", host: "10.0.0.3"}]
    }
  end

  defp app_ctx(attrs \\ %{}) do
    spec =
      Map.merge(
        %{
          application: "my-api",
          type: :elixir_release,
          version: "0.0.1+abc",
          domain: "my-api.example.com"
        },
        attrs
      )

    %{spec: spec, target_port: 4_321, target_symlink: "/var/apps/my-api/current_blue"}
  end

  defp bootstrap_routes(opts \\ []) do
    %{}
    |> CaddyBootstrap.rebuild(Keyword.merge([backend: "localhost:4000", http_port: 8080], opts))
    |> get_in(["apps", "http", "servers", "still", "routes"])
  end

  defp handlers(%{"handle" => handle}), do: Enum.map(handle, & &1["handler"])

  defp route(routes, id), do: Enum.find(routes, &(&1["@id"] == id))

  describe "enabled?/0" do
    test "is off by default" do
      refute Tracing.enabled?()
    end

    @tag tracing: true
    test "is on when :caddy_tracing is true" do
      assert Tracing.enabled?()
    end

    @tag tracing: "1"
    test "requires the literal boolean, not a truthy value" do
      refute Tracing.enabled?()
    end
  end

  describe "prepend/2" do
    test "returns the handle list unchanged when disabled" do
      handle = [%{"handler" => "reverse_proxy"}]
      assert Tracing.prepend(handle, "my-api") == handle
    end

    @tag tracing: true
    test "prepends the tracing handler so the span covers the rest of the chain" do
      handle = [%{"handler" => "reverse_proxy"}]

      assert [%{"handler" => "tracing", "span" => "my-api"}, %{"handler" => "reverse_proxy"}] =
               Tracing.prepend(handle, "my-api")
    end

    @tag tracing: true
    test "sets http.route to the application name so APM resource names split per app" do
      [tracing | _] = Tracing.prepend([%{"handler" => "reverse_proxy"}], "my-api")
      assert tracing["span_attributes"] == %{"http.route" => "my-api"}
    end
  end

  describe "controller ingress routes" do
    test "carry no tracing handler by default" do
      [route] = Ingress.build_routes([app_entry("my-api")])
      assert handlers(route) == ["reverse_proxy"]
    end

    @tag tracing: true
    test "are traced with a span named after the application" do
      [route] = Ingress.build_routes([app_entry("my-api")])

      assert [
               %{
                 "handler" => "tracing",
                 "span" => "my-api",
                 "span_attributes" => %{"http.route" => "my-api"}
               },
               %{"handler" => "reverse_proxy"}
             ] = route["handle"]
    end

    @tag tracing: true
    test "get one span name per application" do
      routes = Ingress.build_routes([app_entry("my-api"), app_entry("marketing")])
      assert Enum.map(routes, &hd(&1["handle"])["span"]) == ["my-api", "marketing"]
    end

    @tag tracing: true
    test "get one http.route attribute per application" do
      routes = Ingress.build_routes([app_entry("my-api"), app_entry("marketing")])

      assert Enum.map(routes, &hd(&1["handle"])["span_attributes"]) == [
               %{"http.route" => "my-api"},
               %{"http.route" => "marketing"}
             ]
    end

    @tag tracing: true
    test "trace a maintenance page too, so parked traffic is still visible" do
      entry = app_entry("my-api", %{maintenance: true, maintenance_message: "brb"})
      [route] = Ingress.build_routes([entry])

      assert [
               %{"handler" => "tracing", "span" => "my-api"},
               %{"handler" => "static_response", "status_code" => 503}
             ] = route["handle"]
    end

    @tag tracing: true
    test "keep the health check and lb policy on the proxy handler" do
      [route] = Ingress.build_routes([app_entry("my-api")])
      assert [_tracing, proxy] = route["handle"]
      assert proxy["health_checks"]["active"]["uri"] == "/health"
      assert proxy["load_balancing"]["selection_policy"]["policy"] == "ip_hash"
    end
  end

  describe "agent-local application routes" do
    test "carry no tracing handler by default" do
      assert handlers(DeploymentManager.build_app_route(app_ctx())) == ["reverse_proxy"]
    end

    @tag tracing: true
    test "are traced with a span named after the application" do
      route = DeploymentManager.build_app_route(app_ctx())

      assert [
               %{
                 "handler" => "tracing",
                 "span" => "my-api",
                 "span_attributes" => %{"http.route" => "my-api"}
               },
               %{"handler" => "reverse_proxy"}
             ] = route["handle"]
    end

    @tag tracing: true
    test "trace a static_site ahead of its subroute" do
      route = DeploymentManager.build_app_route(app_ctx(%{type: :static_site}))

      assert [%{"handler" => "tracing", "span" => "my-api"}, %{"handler" => "subroute"}] =
               route["handle"]
    end

    @tag tracing: true
    test "trace a maintenance page too" do
      route =
        DeploymentManager.build_app_route(
          app_ctx(%{maintenance: true, maintenance_message: "brb"})
        )

      assert [
               %{"handler" => "tracing", "span" => "my-api"},
               %{"handler" => "static_response", "status_code" => 503}
             ] = route["handle"]
    end
  end

  describe "system routes" do
    test "controller route carries no tracing handler by default" do
      assert handlers(route(bootstrap_routes(), "still_controller")) == ["reverse_proxy"]
    end

    @tag tracing: true
    test "controller route is never traced — Still's own dashboard stays out of traces" do
      assert handlers(route(bootstrap_routes(), "still_controller")) == ["reverse_proxy"]
    end

    @tag tracing: true
    test "catch-all is never traced" do
      assert handlers(route(bootstrap_routes(), "still_catchall")) == ["static_response"]
    end

    @tag tracing: true
    test "internal artifacts server is never traced" do
      config = CaddyBootstrap.rebuild(%{}, backend: "localhost:4000", http_port: 8080)
      [route] = get_in(config, ["apps", "http", "servers", "still_internal", "routes"])
      assert handlers(route) == ["vars", "rewrite", "file_server"]
    end

    @tag tracing: true
    test "app routes already in the config are preserved untouched by a rebuild" do
      existing = %{
        "@id" => "still_app_my-api",
        "handle" => [%{"handler" => "reverse_proxy", "upstreams" => [%{"dial" => "x:1"}]}]
      }

      current = %{
        "apps" => %{"http" => %{"servers" => %{"still" => %{"routes" => [existing]}}}}
      }

      rebuilt =
        current
        |> CaddyBootstrap.rebuild(backend: "localhost:4000", http_port: 8080)
        |> get_in(["apps", "http", "servers", "still", "routes"])

      assert route(rebuilt, "still_app_my-api") == existing
    end
  end
end
