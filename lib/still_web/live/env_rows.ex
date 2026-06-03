defmodule StillWeb.EnvRows do
  @moduledoc """
  Shared helpers for the env-var key/value row editor used by the application
  create and edit dialogs.
  """

  alias Still.Applications.EnvVars

  @doc "Parses indexed `env[i][key|value]` form params into ordered rows."
  def from_params(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {index, _row} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, %{"key" => key, "value" => value}} -> %{key: key, value: value} end)
  end

  @doc "Builds editor rows from a stored env var map, sorted by key."
  def to_rows(env_vars) when is_map(env_vars) do
    env_vars
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> %{key: key, value: value} end)
  end

  @doc """
  Validates rows and builds the env var map. Keys are normalized before the
  checks. Returns `{:ok, map}` or `{:error, message}`.
  """
  def to_env_vars(rows) when is_list(rows) do
    rows = Enum.map(rows, &%{&1 | key: EnvVars.normalize_key(&1.key)})

    cond do
      Enum.any?(rows, &(&1.key == "" and &1.value != "")) ->
        {:error, "Every value needs a key."}

      duplicate_keys?(rows) ->
        {:error, "Duplicate keys aren't allowed."}

      true ->
        {:ok, rows |> Enum.reject(&(&1.key == "")) |> Map.new(&{&1.key, &1.value})}
    end
  end

  defp duplicate_keys?(rows) do
    keys = rows |> Enum.map(& &1.key) |> Enum.reject(&(&1 == ""))
    keys != Enum.uniq(keys)
  end
end
