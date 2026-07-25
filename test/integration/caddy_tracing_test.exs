defmodule Still.Integration.CaddyTracingTest do
  @moduledoc """
  Proves opt-in tracing against a real Caddy and a real OTLP collector: that
  Caddy accepts the `tracing` handler Still emits, that traffic still serves
  normally with it in the chain, that a span named after the application
  actually reaches the collector, and that Caddy forwards `traceparent` to
  the upstream so an instrumented application's trace nests under Caddy's.

  Unit tests can only pin the JSON Still generates. A wrong handler name or
  field would satisfy them and fail at deploy time in production, when Caddy
  rejects the config.
  """
  use Still.IntegrationCase, otlp: true

  alias Still.Agent.CaddyManager
  alias Still.Agent.DeploymentManager
  alias Still.Applications.Application, as: App
  alias Still.Caddy.Tracing
  alias Still.Fleet.Server
  alias Still.Ingress
  alias Still.IntegrationFixtures
  alias Still.RecordingServer

  setup do
    original = Elixir.Application.get_env(:still, :caddy_tracing)
    Elixir.Application.put_env(:still, :caddy_tracing, true)
    on_exit(fn -> Elixir.Application.put_env(:still, :caddy_tracing, original) end)
    :ok
  end

  describe "agent-local application routes" do
    test "a deploy Caddy accepts serves normally and exports a span named after the app",
         %{caddy: caddy, otlp: otlp} do
      assert Tracing.enabled?()

      start_supervised!(DeploymentManager)

      # Caddy validates the whole config on load, so a deploy that returns
      # {:ok, _} is Caddy accepting the tracing handler we emit.
      assert {:ok, "0.0.1-a"} =
               DeploymentManager.deploy(spec("traced-app", "traced.example.test"))

      assert %{status: 200, body: body} = get_host(caddy.http_port, "traced.example.test")
      assert body =~ "still-fixture-static vA"

      RecordingServer.await_span!(otlp, "traced-app")
    end

    test "the emitted route really does carry the handler Caddy accepted" do
      start_supervised!(DeploymentManager)
      assert {:ok, _} = DeploymentManager.deploy(spec("shape-app", "shape.example.test"))

      assert [%{"handler" => "tracing", "span" => "shape-app"} | _] =
               live_route("still_app_shape-app")["handle"]
    end
  end

  describe "controller ingress routes" do
    test "export a span and propagate traceparent to the agent upstream",
         %{caddy: caddy, otlp: otlp} do
      upstream = RecordingServer.start!()
      on_exit(fn -> RecordingServer.stop!(upstream) end)

      # Ingress dials each assigned server on :ingress_edge_port; point that at
      # the recording server so it stands in for the agent's Caddy.
      original_port = Elixir.Application.get_env(:still, :ingress_edge_port)
      Elixir.Application.put_env(:still, :ingress_edge_port, upstream.port)
      on_exit(fn -> Elixir.Application.put_env(:still, :ingress_edge_port, original_port) end)

      app =
        struct(App, %{name: "ingress-app", type: :static_site, domain: "ingress.example.test"})

      server = %Server{id: Ecto.UUID.generate(), name: "agent-1", host: "127.0.0.1"}

      assert :ok = load_routes(Ingress.build_routes([%{application: app, servers: [server]}]))

      assert %{status: 200} = get_host(caddy.http_port, "ingress.example.test")

      # The upstream saw a W3C traceparent, which is what makes the
      # application's own spans children of Caddy's.
      traceparent = RecordingServer.recorded_header(upstream, "traceparent")
      assert is_binary(traceparent)
      assert traceparent =~ ~r/^00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]$/

      RecordingServer.await_span!(otlp, "ingress-app")
    end
  end

  describe "with tracing disabled" do
    test "the deployed route carries no tracing handler and nothing is exported",
         %{caddy: caddy, otlp: otlp} do
      Elixir.Application.put_env(:still, :caddy_tracing, false)

      start_supervised!(DeploymentManager)
      assert {:ok, _} = DeploymentManager.deploy(spec("untraced-app", "untraced.example.test"))
      assert %{status: 200} = get_host(caddy.http_port, "untraced.example.test")

      assert [%{"handler" => "subroute"}] = live_route("still_app_untraced-app")["handle"]

      # A traced request through the same Caddy, exported after the untraced
      # one, is the flush barrier: once the canary's span has landed the
      # exporter has drained past the untraced request, so its absence is real
      # rather than a span still sitting in the batch queue.
      Elixir.Application.put_env(:still, :caddy_tracing, true)
      assert {:ok, _} = DeploymentManager.deploy(spec("canary-app", "canary.example.test"))
      assert %{status: 200} = get_host(caddy.http_port, "canary.example.test")
      RecordingServer.await_span!(otlp, "canary-app")

      refute RecordingServer.exported_span?(otlp, "untraced-app")
    end
  end

  defp spec(application, domain) do
    %{
      application: application,
      type: :static_site,
      version: "0.0.1-a",
      artifact_url: IntegrationFixtures.file_url(:static_a),
      artifact_provider: Still.Artifact.Provider.LocalFile,
      domain: domain,
      env_vars: %{},
      exec_command: nil,
      health_check: nil,
      hooks: %{},
      port_blue: nil,
      port_green: nil
    }
  end

  defp load_routes(routes) do
    {:ok, config} = CaddyManager.get_config()

    CaddyManager.load_config(
      put_in(config, ["apps", "http", "servers", "still", "routes"], routes)
    )
  end

  defp live_route(id) do
    {:ok, config} = CaddyManager.get_config()

    config
    |> get_in(["apps", "http", "servers", "still", "routes"])
    |> Enum.find(&(&1["@id"] == id))
  end

  defp get_host(http_port, host) do
    Req.get!("http://localhost:#{http_port}/", headers: [{"host", host}], retry: false)
  end
end
