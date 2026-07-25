defmodule Still.IngressTest do
  use ExUnit.Case, async: true

  alias Still.Applications.Application
  alias Still.Applications.HealthCheck
  alias Still.Fleet.Server
  alias Still.Ingress

  defp server(host, name \\ nil) do
    %Server{
      id: Ecto.UUID.generate(),
      name: name || "agent-#{host}",
      host: host,
      roles: ["application"]
    }
  end

  defp elixir_app(attrs \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      name: "api",
      type: :elixir_release,
      domain: "api.example.com",
      path_prefix: nil,
      exec_command: "bin/api start",
      health_check: %HealthCheck{
        path: "/health",
        interval_ms: 5_000,
        deadline_ms: 3_000
      }
    }

    struct(Application, Map.merge(defaults, attrs))
  end

  defp static_app(attrs \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      name: "marketing",
      type: :static_site,
      domain: "www.example.com",
      path_prefix: nil,
      health_check: nil
    }

    struct(Application, Map.merge(defaults, attrs))
  end

  describe "build_routes/1" do
    test "returns an empty list when given no entries" do
      assert Ingress.build_routes([]) == []
    end

    test "skips entries with no assigned servers" do
      entry = %{application: elixir_app(), servers: []}
      assert Ingress.build_routes([entry]) == []
    end

    test "builds one route per assigned application" do
      entries = [
        %{application: elixir_app(%{name: "api"}), servers: [server("10.0.0.3")]},
        %{application: static_app(%{name: "marketing"}), servers: [server("10.0.0.4")]}
      ]

      routes = Ingress.build_routes(entries)
      ids = Enum.map(routes, & &1["@id"])
      assert ids == ["still_ingress_api", "still_ingress_marketing"]
    end

    # Enabled-path coverage lives in Still.Caddy.TracingTest, which flips the
    # global knob and so can't be async.
    test "carries no tracing handler while caddy_tracing is off" do
      entries = [%{application: elixir_app(), servers: [server("10.0.0.3")]}]
      [route] = Ingress.build_routes(entries)
      assert [%{"handler" => "reverse_proxy"}] = route["handle"]
    end

    test "route carries host matcher for the app domain" do
      entries = [%{application: elixir_app(%{domain: "api.test"}), servers: [server("10.0.0.3")]}]
      [route] = Ingress.build_routes(entries)
      assert [%{"host" => ["api.test"]}] = route["match"]
    end

    test "route carries path matcher when path_prefix is set" do
      entries = [
        %{
          application: elixir_app(%{domain: "example.com", path_prefix: "/api"}),
          servers: [server("10.0.0.3")]
        }
      ]

      [route] = Ingress.build_routes(entries)
      assert [%{"host" => ["example.com"], "path" => ["/api*"]}] = route["match"]
    end

    test "serves a 503 maintenance page instead of proxying when the app is in maintenance" do
      entries = [
        %{
          application: elixir_app(%{maintenance: true, maintenance_message: "Back soon"}),
          servers: [server("10.0.0.3")]
        }
      ]

      [route] = Ingress.build_routes(entries)

      assert [%{"handler" => "static_response", "status_code" => 503, "body" => "Back soon"}] =
               route["handle"]

      # Still host-matched and terminal, so the page answers on the app's domain.
      assert [%{"host" => ["api.example.com"]}] = route["match"]
      assert route["terminal"] == true
    end

    test "omits path matcher when path_prefix is nil or empty" do
      for prefix <- [nil, ""] do
        entries = [
          %{
            application: elixir_app(%{path_prefix: prefix}),
            servers: [server("10.0.0.3")]
          }
        ]

        [route] = Ingress.build_routes(entries)
        [match] = route["match"]

        refute Map.has_key?(match, "path"),
               "expected no path matcher for prefix #{inspect(prefix)}"
      end
    end

    test "reverse_proxy includes every assigned agent as a dial on port 80" do
      entries = [
        %{
          application: elixir_app(),
          servers: [server("10.0.0.3"), server("10.0.0.4"), server("10.0.0.5")]
        }
      ]

      [route] = Ingress.build_routes(entries)
      [handle] = route["handle"]
      dials = Enum.map(handle["upstreams"], & &1["dial"])
      assert dials == ["10.0.0.3:8080", "10.0.0.4:8080", "10.0.0.5:8080"]
    end

    test "elixir_release apps get an active health check from their health_check config" do
      entries = [
        %{
          application:
            elixir_app(%{
              health_check: %HealthCheck{
                path: "/healthz",
                interval_ms: 10_000,
                deadline_ms: 2_000
              }
            }),
          servers: [server("10.0.0.3")]
        }
      ]

      [route] = Ingress.build_routes(entries)
      [handle] = route["handle"]

      assert handle["health_checks"] == %{
               "active" => %{
                 "uri" => "/healthz",
                 "interval" => "10000ms",
                 "timeout" => "2000ms"
               }
             }
    end

    test "static_site apps get no health check" do
      entries = [%{application: static_app(), servers: [server("10.0.0.3")]}]

      [route] = Ingress.build_routes(entries)
      [handle] = route["handle"]
      refute Map.has_key?(handle, "health_checks")
    end

    test "elixir_release apps get ip_hash load balancing for stickiness" do
      entries = [
        %{application: elixir_app(), servers: [server("10.0.0.3"), server("10.0.0.4")]}
      ]

      [route] = Ingress.build_routes(entries)
      [handle] = route["handle"]

      assert handle["load_balancing"] == %{
               "selection_policy" => %{"policy" => "ip_hash"}
             }
    end

    test "static_site apps get no load balancing policy (random is fine)" do
      entries = [
        %{application: static_app(), servers: [server("10.0.0.3"), server("10.0.0.4")]}
      ]

      [route] = Ingress.build_routes(entries)
      [handle] = route["handle"]
      refute Map.has_key?(handle, "load_balancing")
    end

    test "every ingress route is terminal so it stops evaluation on match" do
      entries = [%{application: elixir_app(), servers: [server("10.0.0.3")]}]
      [route] = Ingress.build_routes(entries)
      assert route["terminal"] == true
    end
  end

  describe "ingress_route?/1" do
    test "true for routes whose @id has the ingress prefix" do
      assert Ingress.ingress_route?(%{"@id" => "still_ingress_api"})
    end

    test "false for system routes" do
      refute Ingress.ingress_route?(%{"@id" => "still_api"})
      refute Ingress.ingress_route?(%{"@id" => "still_dashboard"})
    end

    test "false for agent-local app routes" do
      refute Ingress.ingress_route?(%{"@id" => "still_app_my-api"})
    end

    test "false for routes with no @id" do
      refute Ingress.ingress_route?(%{"handle" => []})
    end
  end

  describe "id_prefix/0" do
    test "returns the prefix used for every ingress route" do
      assert Ingress.id_prefix() == "still_ingress_"
    end
  end
end
