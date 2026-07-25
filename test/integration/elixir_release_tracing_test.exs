defmodule Still.Integration.ElixirReleaseTracingTest do
  @moduledoc """
  The traced path for a real `:elixir_release`: a systemd-supervised release
  behind a Caddy `reverse_proxy`, exporting spans to a real OTLP collector
  across a blue/green flip.

  The static_site integration test covers a `subroute`/`file_server` handle;
  this one covers the proxy handle and, crucially, that a redeploy rewrites
  the route with the tracing handler still on it — the re-emit path operators
  rely on when they enable tracing after an application is already deployed.
  """
  use Still.IntegrationCase, root: true, otlp: true

  alias Still.Agent.CaddyManager
  alias Still.Agent.DeploymentManager
  alias Still.Agent.HealthMonitor
  alias Still.IntegrationFixtures
  alias Still.RecordingServer

  @application "test-still-tracing-release"

  setup do
    cleanup_systemd_units(@application)
    on_exit(fn -> cleanup_systemd_units(@application) end)

    original = Elixir.Application.get_env(:still, :caddy_tracing)
    Elixir.Application.put_env(:still, :caddy_tracing, true)
    on_exit(fn -> Elixir.Application.put_env(:still, :caddy_tracing, original) end)

    {:ok, ports: %{blue: free_port(), green: free_port()}}
  end

  test "traces a release through Caddy and keeps tracing across a blue/green flip",
       %{caddy: caddy, otlp: otlp, ports: ports} do
    start_supervised!(HealthMonitor)
    start_supervised!(DeploymentManager)

    # Caddy validates on /load, so a successful deploy is Caddy accepting the
    # tracing handler ahead of a reverse_proxy.
    assert {:ok, "0.0.1-a"} = DeploymentManager.deploy(spec(:release_a, "0.0.1-a", ports))
    assert fetch_body(caddy.http_port, "/") =~ "vA"

    assert [
             %{
               "handler" => "tracing",
               "span" => @application,
               "span_attributes" => %{"http.route" => @application}
             },
             %{"handler" => "reverse_proxy"}
           ] = app_route()["handle"]

    RecordingServer.await_span!(otlp, @application)

    # A redeploy rewrites the route wholesale; the handler has to come back.
    assert {:ok, "0.0.1-b"} = DeploymentManager.deploy(spec(:release_b, "0.0.1-b", ports))
    assert fetch_body(caddy.http_port, "/") =~ "vB"

    assert [
             %{
               "handler" => "tracing",
               "span" => @application,
               "span_attributes" => %{"http.route" => @application}
             },
             %{"handler" => "reverse_proxy"}
           ] = app_route()["handle"]
  end

  defp spec(fixture, version, ports) do
    %{
      application: @application,
      type: :elixir_release,
      version: version,
      artifact_url: IntegrationFixtures.file_url(fixture),
      artifact_provider: Still.Artifact.Provider.LocalFile,
      domain: "localhost",
      env_vars: %{},
      exec_command: "bin/elixir_release start",
      exec_start_pre: nil,
      exec_stop: nil,
      user: nil,
      health_check: %{path: "/health", interval_ms: 500, deadline_ms: 30_000},
      hooks: %{},
      port_blue: ports.blue,
      port_green: ports.green
    }
  end

  defp app_route do
    {:ok, config} = CaddyManager.get_config()

    config
    |> get_in(["apps", "http", "servers", "still", "routes"])
    |> Enum.find(&(&1["@id"] == "still_app_#{@application}"))
  end

  defp fetch_body(http_port, path) do
    %{status: 200, body: body} = Req.get!("http://localhost:#{http_port}#{path}", retry: false)
    body
  end
end
