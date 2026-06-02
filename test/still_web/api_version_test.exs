defmodule StillWeb.APIVersionTest do
  use ExUnit.Case, async: true

  alias StillWeb.APIVersion

  describe "current/0" do
    test "returns the exact pinned version string" do
      # Exact-match — the version IS the contract. Any change to it means
      # a breaking API change, which is exactly the kind of thing a test
      # should force someone to look at.
      assert APIVersion.current() == "2026-04-09"
    end

    test "is a parseable ISO-8601 date no later than today" do
      # Defensive sanity check: if someone bumps the constant to garbage
      # or to a future date, catch it here.
      assert {:ok, date} = Date.from_iso8601(APIVersion.current())
      assert Date.compare(date, Date.utc_today()) in [:lt, :eq]
    end
  end
end
