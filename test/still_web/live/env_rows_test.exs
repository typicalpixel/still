defmodule StillWeb.EnvRowsTest do
  use ExUnit.Case, async: true

  alias StillWeb.EnvRows

  describe "from_params/1" do
    test "orders rows by numeric index" do
      params = %{
        "1" => %{"key" => "B", "value" => "2"},
        "0" => %{"key" => "A", "value" => "1"},
        "10" => %{"key" => "C", "value" => "3"}
      }

      assert EnvRows.from_params(params) == [
               %{key: "A", value: "1"},
               %{key: "B", value: "2"},
               %{key: "C", value: "3"}
             ]
    end
  end

  describe "to_rows/1" do
    test "sorts a stored map by key" do
      assert EnvRows.to_rows(%{"B" => "2", "A" => "1"}) == [
               %{key: "A", value: "1"},
               %{key: "B", value: "2"}
             ]
    end
  end

  describe "to_env_vars/1" do
    test "normalizes keys and builds the map" do
      rows = [%{key: "database-url", value: "x"}, %{key: "port", value: "4000"}]
      assert EnvRows.to_env_vars(rows) == {:ok, %{"DATABASE_URL" => "x", "PORT" => "4000"}}
    end

    test "drops fully blank rows" do
      rows = [%{key: "FOO", value: "bar"}, %{key: "", value: ""}]
      assert EnvRows.to_env_vars(rows) == {:ok, %{"FOO" => "bar"}}
    end

    test "rejects a value without a key" do
      assert EnvRows.to_env_vars([%{key: "", value: "orphan"}]) ==
               {:error, "Every value needs a key."}
    end

    test "rejects keys that collide after normalization" do
      rows = [%{key: "db-url", value: "a"}, %{key: "DB_URL", value: "b"}]
      assert EnvRows.to_env_vars(rows) == {:error, "Duplicate keys aren't allowed."}
    end
  end
end
