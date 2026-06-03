defmodule Still.Integration.StaticSiteCacheTest do
  use Still.IntegrationCase

  alias Still.Agent.DeploymentManager
  alias Still.IntegrationFixtures

  test "serves the SPA with split caching, deep-link fallback, and compression",
       %{caddy: caddy} do
    spec = %{
      application: "integration-static-cache",
      type: :static_site,
      version: "0.0.1-a",
      artifact_url: IntegrationFixtures.file_url(:static_a),
      artifact_provider: Still.Artifact.Provider.LocalFile,
      domain: "localhost",
      env_vars: %{},
      exec_command: nil,
      health_check: nil,
      hooks: %{},
      port_blue: nil,
      port_green: nil
    }

    start_supervised!(DeploymentManager)
    assert {:ok, "0.0.1-a"} = DeploymentManager.deploy(spec)

    base = "http://localhost:#{caddy.http_port}"

    # The unhashed app shell must never be cached.
    shell = Req.get!("#{base}/", retry: false)
    assert shell.status == 200
    assert get_header(shell, "cache-control") =~ "no-cache"

    # A deep link with no file on disk falls back to the shell — 200, app
    # content, and the same no-cache header (not the immutable asset rule).
    deep = Req.get!("#{base}/some/client/route", retry: false)
    assert deep.status == 200
    assert deep.body =~ "still-fixture-static"
    assert get_header(deep, "cache-control") =~ "no-cache"

    # The content-hashed asset referenced by the shell is cached forever.
    asset_path = Regex.run(~r{/assets/[^"]+}, shell.body) |> hd()
    asset = Req.get!("#{base}#{asset_path}", retry: false)
    assert asset.status == 200
    assert get_header(asset, "cache-control") == "public, max-age=31536000, immutable"

    # Compression is negotiated when the client offers it.
    compressed =
      Req.get!("#{base}#{asset_path}",
        retry: false,
        headers: [{"accept-encoding", "gzip"}],
        raw: true,
        decode_body: false
      )

    assert get_header(compressed, "content-encoding") == "gzip"
  end

  defp get_header(%{headers: headers}, name) do
    case Map.get(headers, name) do
      [value | _] -> value
      _ -> nil
    end
  end
end
