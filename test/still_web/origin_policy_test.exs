defmodule StillWeb.OriginPolicyTest do
  use ExUnit.Case, async: true

  alias StillWeb.OriginPolicy

  describe "check_origin/2" do
    test "a controller domain with no override locks to that host across schemes/ports" do
      assert OriginPolicy.check_origin("still.example.com", nil) == ["//still.example.com"]
    end

    test "trims whitespace around the domain" do
      assert OriginPolicy.check_origin("  still.example.com  ", nil) == ["//still.example.com"]
    end

    test "a blank or missing domain allows any origin" do
      assert OriginPolicy.check_origin(nil, nil) == false
      assert OriginPolicy.check_origin("", nil) == false
      assert OriginPolicy.check_origin("   ", nil) == false
    end

    test "an override wins and is parsed as a comma-separated allow-list" do
      assert OriginPolicy.check_origin("still.example.com", "//app.example.com, //*.example.com") ==
               ["//app.example.com", "//*.example.com"]
    end

    test "a blank or empty override falls back to the domain rule" do
      assert OriginPolicy.check_origin("still.example.com", "   ") == ["//still.example.com"]
      assert OriginPolicy.check_origin("still.example.com", ", ,") == ["//still.example.com"]
      assert OriginPolicy.check_origin(nil, "") == false
    end
  end
end
