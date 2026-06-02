defmodule StillWeb.ApiKeyJSONTest do
  use ExUnit.Case, async: true

  alias Still.Accounts.ApiKey
  alias StillWeb.ApiKeyJSON

  defp sample_key(overrides \\ %{}) do
    base = %ApiKey{
      id: "key-1",
      name: "ci-github",
      permissions: ["deploy"],
      last_used_at: ~U[2026-04-20 12:00:00.000000Z],
      inserted_at: ~U[2026-04-01 09:00:00.000000Z]
    }

    struct(base, overrides)
  end

  describe "api_key/1" do
    test "emits the safe-to-return fields" do
      shape = ApiKeyJSON.api_key(sample_key())

      assert %{
               id: "key-1",
               name: "ci-github",
               permissions: ["deploy"],
               last_used_at: %DateTime{},
               inserted_at: %DateTime{}
             } = shape

      refute Map.has_key?(shape, :hashed_key)
      refute Map.has_key?(shape, :raw_key)
    end
  end

  describe "render/1" do
    test "wraps a list under data" do
      assert %{data: [%{id: "key-1"}]} = ApiKeyJSON.render([sample_key()])
    end

    test "returns an empty list unchanged" do
      assert %{data: []} = ApiKeyJSON.render([])
    end
  end

  describe "render_created/1" do
    test "includes the raw key exactly once" do
      key = sample_key(%{raw_key: "still_abcdef"})
      assert %{data: %{raw_key: "still_abcdef", id: "key-1"}} = ApiKeyJSON.render_created(key)
    end
  end
end
