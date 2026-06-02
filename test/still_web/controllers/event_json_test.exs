defmodule StillWeb.EventJSONTest do
  use ExUnit.Case, async: true

  alias StillWeb.EventJSON

  @at ~U[2026-04-20 15:00:00.000000Z]

  describe "event/1" do
    test "emits id, type, payload, at" do
      assert %{id: "evt_1", type: :server_connected, payload: %{k: "v"}, at: @at} =
               EventJSON.event(%{
                 id: "evt_1",
                 type: :server_connected,
                 payload: %{k: "v"},
                 at: @at
               })
    end
  end

  describe "render/1" do
    test "wraps a list under data" do
      assert %{data: [%{id: "evt_1"}]} =
               EventJSON.render([
                 %{id: "evt_1", type: :foo, payload: %{}, at: @at}
               ])
    end

    test "empty list stays empty" do
      assert %{data: []} = EventJSON.render([])
    end
  end
end
