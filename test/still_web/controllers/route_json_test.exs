defmodule StillWeb.RouteJSONTest do
  use ExUnit.Case, async: true

  alias StillWeb.RouteJSON

  defp sample_route do
    %{
      application: %{
        name: "my-api",
        type: :elixir_release,
        domain: "api.example.com",
        path_prefix: "/v1"
      },
      servers: [
        %{id: "srv-1", name: "bm-fra-01", host: "10.10.0.11"},
        %{id: "srv-2", name: "bm-fra-02", host: "10.10.0.12"}
      ]
    }
  end

  describe "upstream/1" do
    test "builds the host/port pair and dial string" do
      assert %{
               server_id: "srv-1",
               server_name: "bm-fra-01",
               host: "10.10.0.11",
               port: 8080,
               dial: "10.10.0.11:8080"
             } = RouteJSON.upstream(%{id: "srv-1", name: "bm-fra-01", host: "10.10.0.11"})
    end
  end

  describe "route/1" do
    test "emits the application fields plus one upstream per assigned server" do
      shape = RouteJSON.route(sample_route())

      assert shape.name == "my-api"
      assert shape.type == :elixir_release
      assert shape.domain == "api.example.com"
      assert shape.path_prefix == "/v1"
      assert length(shape.upstreams) == 2
      assert Enum.map(shape.upstreams, & &1.dial) == ["10.10.0.11:8080", "10.10.0.12:8080"]
    end
  end

  describe "render/1" do
    test "wraps a list of routes under data" do
      assert %{data: [%{name: "my-api"}]} = RouteJSON.render([sample_route()])
    end

    test "returns empty data for an empty list" do
      assert %{data: []} = RouteJSON.render([])
    end
  end
end
