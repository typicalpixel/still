defmodule StillWeb.HookJSONTest do
  use ExUnit.Case, async: true

  alias Still.Applications.Hook
  alias StillWeb.HookJSON

  defp sample_hook(overrides \\ %{}) do
    base = %Hook{
      id: "hook-1",
      application_id: "app-1",
      event: :post_deploy,
      script: "echo ok",
      timeout_ms: 30_000,
      inserted_at: ~U[2026-04-01 09:00:00.000000Z],
      updated_at: ~U[2026-04-20 15:00:00.000000Z]
    }

    struct(base, overrides)
  end

  describe "hook/1" do
    test "emits the full shape" do
      assert %{
               id: "hook-1",
               application_id: "app-1",
               event: :post_deploy,
               script: "echo ok",
               timeout_ms: 30_000
             } = HookJSON.hook(sample_hook())
    end
  end

  describe "render/1" do
    test "wraps a list under data" do
      assert %{data: [%{id: "hook-1"}]} = HookJSON.render([sample_hook()])
    end
  end

  describe "render_one/1" do
    test "wraps a single hook under data" do
      assert %{data: %{id: "hook-1"}} = HookJSON.render_one(sample_hook())
    end
  end
end
