defmodule Still.Applications.EnvVars do
  @moduledoc """
  Environment-variable name handling for applications.

  Names are normalized the way Doppler does it: uppercased, with every
  character outside `[A-Z0-9_]` folded to an underscore. This keeps keys valid
  in the systemd `EnvironmentFile` the deploy writes.
  """

  @doc """
  Normalizes an env var name: uppercase, with each character outside
  `[A-Z0-9_]` replaced by an underscore. An empty string stays empty.
  """
  def normalize_key(key) when is_binary(key) do
    key |> String.upcase() |> String.replace(~r/[^A-Z0-9_]/, "_")
  end

  @doc """
  Normalizes every string key in a name/value map; the last value wins on
  collision. Non-string keys are left untouched for validation to reject.
  """
  def normalize_map(vars) when is_map(vars) do
    Map.new(vars, fn
      {key, value} when is_binary(key) -> {normalize_key(key), value}
      {key, value} -> {key, value}
    end)
  end
end
