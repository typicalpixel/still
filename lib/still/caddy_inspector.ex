defmodule Still.CaddyInspector do
  @moduledoc """
  Read-only access to the live Caddy JSON config a node is running, for
  diagnostics. Fetches the local node's config directly from its Caddy admin
  API and a connected agent's config over Erlang distribution.

  Results are normalized to `{:ok, config}` | `{:error, :agent_disconnected}`
  | `{:error, :caddy_unreachable}` so callers don't have to know whether the
  failure was a downed agent or an unhappy Caddy admin API.
  """

  alias Still.Agent.CaddyManager
  alias Still.AgentConnectionManager

  @doc "The local node's Caddy config (the controller/standalone box serving the API)."
  def local_config do
    normalize(CaddyManager.get_config())
  end

  @doc """
  The Caddy config for a fleet server by id. A connected agent's config is
  fetched over distribution; a server with no connected agent returns
  `{:error, :agent_disconnected}`; an unreachable node or unhappy Caddy
  returns `{:error, :caddy_unreachable}`.
  """
  def config_for_server(server_id) when is_binary(server_id) do
    case AgentConnectionManager.get_agent_state(server_id) do
      nil -> {:error, :agent_disconnected}
      %{node: node} -> remote_config(node)
    end
  end

  defp remote_config(node) do
    normalize(:erpc.call(node, CaddyManager, :get_config, []))
  rescue
    _ -> {:error, :caddy_unreachable}
  end

  defp normalize({:ok, config}), do: {:ok, config}
  defp normalize({:error, _reason}), do: {:error, :caddy_unreachable}
end
