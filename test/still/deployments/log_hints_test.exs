defmodule Still.Deployments.LogHintsTest do
  use ExUnit.Case, async: true

  alias Still.Deployments.LogHints

  describe "hint_for/1" do
    test "flags a node-name collision" do
      log = "name forge@host seems to be in use by another Erlang node"
      assert %{title: "Node-name collision"} = LogHints.hint_for(log)
    end

    test "flags a Doppler auth failure" do
      log = "Doppler Error: invalid auth token (401)"
      assert %{title: "Doppler authentication failed"} = LogHints.hint_for(log)
    end

    test "flags a database connection failure" do
      log = "** (DBConnection.ConnectionError) tcp connect: connection refused"
      assert %{title: "Database unreachable"} = LogHints.hint_for(log)
    end

    test "distinguishes a database auth failure from unreachability" do
      log =
        ~s|** (Postgrex.Error) FATAL 28P01 (invalid_password) password authentication failed for user "app"|

      assert %{title: "Database authentication failed"} = LogHints.hint_for(log)
    end

    test "flags an unset environment variable and names it" do
      log =
        ~s|** (RuntimeError) could not fetch environment variable "DATABASE_URL" because it is not set|

      assert %{title: "Missing environment variable: DATABASE_URL"} = LogHints.hint_for(log)
    end

    test "returns nil when nothing matches" do
      assert LogHints.hint_for("everything booted fine on :4000") == nil
    end

    test "does not fire on benign lines that merely mention the keywords" do
      # A healthy boot must not get a confident-but-wrong hint at the top of the panel.
      assert LogHints.hint_for("doppler: loaded 12 secrets; token valid") == nil
      assert LogHints.hint_for("Postgrex connected to db in 4ms") == nil
      assert LogHints.hint_for("epmd: registered node; ready to accept") == nil
    end

    test "returns nil for nil or non-binary input" do
      assert LogHints.hint_for(nil) == nil
      assert LogHints.hint_for(123) == nil
    end
  end
end
