defmodule Still.Applications.EnvVarsTest do
  use ExUnit.Case, async: true

  alias Still.Applications.EnvVars

  describe "normalize_key/1" do
    test "uppercases" do
      assert EnvVars.normalize_key("database_url") == "DATABASE_URL"
    end

    test "folds hyphens, spaces, and dots to underscores" do
      assert EnvVars.normalize_key("database-url") == "DATABASE_URL"
      assert EnvVars.normalize_key("my key") == "MY_KEY"
      assert EnvVars.normalize_key("a.b.c") == "A_B_C"
    end

    test "leaves digits and underscores alone" do
      assert EnvVars.normalize_key("PORT_2") == "PORT_2"
    end

    test "keeps an empty string empty" do
      assert EnvVars.normalize_key("") == ""
    end
  end

  describe "normalize_map/1" do
    test "normalizes every key and keeps values" do
      assert EnvVars.normalize_map(%{"database-url" => "x", "Secret" => "y"}) ==
               %{"DATABASE_URL" => "x", "SECRET" => "y"}
    end

    test "leaves non-string keys untouched for validation to reject" do
      assert EnvVars.normalize_map(%{foo: "bar"}) == %{foo: "bar"}
    end
  end
end
