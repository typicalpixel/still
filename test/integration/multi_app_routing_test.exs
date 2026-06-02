defmodule Still.Integration.MultiAppRoutingTest do
  @moduledoc """
  Two applications share one agent Caddy. Proves the Host-based matcher
  actually separates traffic between co-located apps — the case the
  original single-app integration tests can't cover on their own.

  Also exercises the static_site SPA fallback: a deep link that doesn't
  correspond to a file on disk should rewrite to `/index.html` rather
  than returning 404.
  """

  use Still.IntegrationCase

  alias Still.Agent.DeploymentManager
  alias Still.IntegrationFixtures

  setup do
    start_supervised!(DeploymentManager)
    :ok
  end

  test "two static sites on one Caddy serve different content by Host header",
       %{caddy: caddy} do
    spec_a =
      build_spec(
        "multi-site-a",
        "0.0.1-a",
        "site-a.test",
        IntegrationFixtures.file_url(:static_a)
      )

    spec_b =
      build_spec(
        "multi-site-b",
        "0.0.1-b",
        "site-b.test",
        IntegrationFixtures.file_url(:static_b)
      )

    assert {:ok, _} = DeploymentManager.deploy(spec_a)
    assert {:ok, _} = DeploymentManager.deploy(spec_b)

    # Each Host header hits its own app's content — the matcher separates traffic.
    assert fetch(caddy.http_port, "site-a.test", "/").body =~ "still-fixture-static vA"
    assert fetch(caddy.http_port, "site-b.test", "/").body =~ "still-fixture-static vB"

    # Routes are terminal and Host-scoped; an unknown Host falls through to
    # the `still_catchall` route (kept last by CaddyBootstrap.with_catchall_last),
    # which answers 200 with the "Still" page instead of Caddy's default.
    assert fetch(caddy.http_port, "site-c.test", "/").body == "Still"
  end

  test "redeploying one app does not disturb the other app's route",
       %{caddy: caddy} do
    spec_a =
      build_spec(
        "multi-site-a",
        "0.0.1-a",
        "site-a.test",
        IntegrationFixtures.file_url(:static_a)
      )

    spec_b =
      build_spec(
        "multi-site-b",
        "0.0.1-b",
        "site-b.test",
        IntegrationFixtures.file_url(:static_b)
      )

    assert {:ok, _} = DeploymentManager.deploy(spec_a)
    assert {:ok, _} = DeploymentManager.deploy(spec_b)

    spec_a_v2 = %{
      spec_a
      | version: "0.0.1-a2",
        artifact_url: IntegrationFixtures.file_url(:static_b)
    }

    assert {:ok, _} = DeploymentManager.deploy(spec_a_v2)

    # A's content follows the new artifact; B's content is untouched.
    assert fetch(caddy.http_port, "site-a.test", "/").body =~ "still-fixture-static vB"
    assert fetch(caddy.http_port, "site-b.test", "/").body =~ "still-fixture-static vB"
  end

  test "static_site deep links fall back to /index.html (SPA routing)",
       %{caddy: caddy} do
    spec =
      build_spec(
        "multi-site-spa",
        "0.0.1",
        "spa.test",
        IntegrationFixtures.file_url(:static_a)
      )

    assert {:ok, _} = DeploymentManager.deploy(spec)

    # The deep link does not exist on disk — try_files rewrites the request
    # to /index.html, which the fixture serves. The response body is the
    # same thing a request for "/" would return.
    index = fetch(caddy.http_port, "spa.test", "/").body
    deep = fetch(caddy.http_port, "spa.test", "/does/not/exist").body

    assert index =~ "still-fixture-static vA"
    assert deep == index
  end

  defp build_spec(name, version, domain, artifact_url) do
    %{
      application: name,
      type: :static_site,
      version: version,
      artifact_url: artifact_url,
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

  defp fetch(http_port, host, path) do
    Req.get!("http://localhost:#{http_port}#{path}",
      headers: [{"host", host}],
      retry: false
    )
  end
end
