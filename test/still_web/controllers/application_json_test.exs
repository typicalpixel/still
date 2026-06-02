defmodule StillWeb.ApplicationJSONTest do
  use ExUnit.Case, async: true

  alias Still.Applications.Application
  alias Still.Applications.ArtifactSource
  alias Still.Applications.HealthCheck
  alias StillWeb.ApplicationJSON

  defp sample_application(overrides \\ %{}) do
    base = %Application{
      id: "app-1",
      name: "my-api",
      type: :elixir_release,
      domain: "api.example.com",
      path_prefix: "/v1",
      exec_command: "bin/my_api start",
      env_vars: %{"MIX_ENV" => "prod"},
      min_healthy: 1,
      health_check: %HealthCheck{
        id: "hc-1",
        path: "/health",
        interval_ms: 5000,
        deadline_ms: 3000
      },
      artifact_source: %ArtifactSource{id: "as-1", type: :unauthenticated_url},
      inserted_at: ~U[2026-04-01 09:00:00.000000Z],
      updated_at: ~U[2026-04-20 15:00:00.000000Z]
    }

    struct(base, overrides)
  end

  describe "application/1" do
    test "emits the full shape" do
      shape = ApplicationJSON.application(sample_application())

      assert shape.id == "app-1"
      assert shape.name == "my-api"
      assert shape.type == :elixir_release
      assert shape.health_check == %{path: "/health", interval_ms: 5000, deadline_ms: 3000}
      assert shape.artifact_source == %{type: :unauthenticated_url}
    end
  end

  describe "embed/1" do
    test "returns nil unchanged" do
      assert ApplicationJSON.embed(nil) == nil
    end

    test "converts an embed to a map and drops :id" do
      hc = %HealthCheck{id: "hc-1", path: "/h", interval_ms: 1, deadline_ms: 1}
      shape = ApplicationJSON.embed(hc)

      refute Map.has_key?(shape, :id)
      assert shape.path == "/h"
    end
  end

  describe "render/1" do
    test "wraps a list under data" do
      assert %{data: [%{id: "app-1"}]} = ApplicationJSON.render([sample_application()])
    end
  end

  describe "render_one/1" do
    test "wraps a single application under data" do
      assert %{data: %{id: "app-1"}} = ApplicationJSON.render_one(sample_application())
    end
  end
end
