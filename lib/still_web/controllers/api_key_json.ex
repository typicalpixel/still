defmodule StillWeb.ApiKeyJSON do
  @moduledoc """
  JSON serialization for API-key endpoints. Hash bytes never appear in
  these shapes — the raw key is included only on create (and only once,
  right after minting).
  """

  alias Still.Accounts.ApiKey

  @doc "Renders a list of API keys for the index endpoint."
  def render(keys) when is_list(keys) do
    %{data: Enum.map(keys, &api_key/1)}
  end

  @doc """
  Renders the response to a create call — the base shape plus the raw
  key, which is only accessible here.
  """
  def render_created(%ApiKey{raw_key: raw} = key) when is_binary(raw) do
    %{data: key |> api_key() |> Map.put(:raw_key, raw)}
  end

  @doc "Base shape — safe-to-return fields for any API key."
  def api_key(%ApiKey{} = key) do
    %{
      id: key.id,
      name: key.name,
      permissions: key.permissions,
      last_used_at: key.last_used_at,
      inserted_at: key.inserted_at
    }
  end
end
