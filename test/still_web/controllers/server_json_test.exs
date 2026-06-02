defmodule StillWeb.ServerJSONTest do
  use ExUnit.Case, async: true

  alias Still.Fleet.Server
  alias StillWeb.ServerJSON

  defp sample_server(overrides \\ %{}) do
    base = %Server{
      id: "srv-1",
      name: "bm-fra-01",
      host: "10.10.0.11",
      roles: ["application"],
      last_seen_at: ~U[2026-04-20 15:00:00.000000Z],
      metadata: %{"hostname" => "bm-fra-01", "cpu_count" => 8},
      inserted_at: ~U[2026-04-01 09:00:00.000000Z],
      updated_at: ~U[2026-04-20 15:00:00.000000Z]
    }

    struct(base, overrides)
  end

  describe "server/2" do
    test "emits :connected when the caller passes connected? = true" do
      shape = ServerJSON.server(sample_server(), true)

      assert shape.id == "srv-1"
      assert shape.name == "bm-fra-01"
      assert shape.host == "10.10.0.11"
      assert shape.roles == ["application"]
      assert shape.status == :connected
      assert shape.metadata["hostname"] == "bm-fra-01"
    end

    test "defaults status to :disconnected" do
      shape = ServerJSON.server(sample_server())
      assert shape.status == :disconnected
    end
  end

  describe "render/2" do
    test "marks servers in connected_ids as connected and others as disconnected" do
      s1 = sample_server(id: "srv-1")
      s2 = sample_server(id: "srv-2")
      connected = MapSet.new(["srv-1"])

      %{data: [one, two]} = ServerJSON.render([s1, s2], connected)
      assert one.id == "srv-1"
      assert one.status == :connected
      assert two.id == "srv-2"
      assert two.status == :disconnected
    end

    test "defaults every server to :disconnected when no set is passed" do
      assert %{data: [%{status: :disconnected}]} = ServerJSON.render([sample_server()])
    end
  end

  describe "render_one/2" do
    test "wraps a single server with the caller-supplied connection flag" do
      assert %{data: %{id: "srv-1", status: :connected}} =
               ServerJSON.render_one(sample_server(), true)
    end

    test "defaults the connection flag to false" do
      assert %{data: %{status: :disconnected}} = ServerJSON.render_one(sample_server())
    end
  end
end
