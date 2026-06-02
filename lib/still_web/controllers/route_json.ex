defmodule StillWeb.RouteJSON do
  @moduledoc """
  JSON serialization for the routing-registry endpoint.

  Upstream port comes from `:ingress_edge_port` (default 8080, override
  with `STILL_INGRESS_EDGE_PORT`). All agents in the fleet share one
  port; if mixed ports ever become a thing this moves to a per-server
  field.
  """

  @doc "Renders the full routing registry — one entry per application."
  def render(routes) when is_list(routes) do
    %{data: Enum.map(routes, &route/1)}
  end

  @doc "Base shape for one route."
  def route(%{application: app, servers: servers}) do
    %{
      name: app.name,
      type: app.type,
      domain: app.domain,
      path_prefix: app.path_prefix,
      upstreams: Enum.map(servers, &upstream/1)
    }
  end

  @doc "One upstream entry: the `(host, port)` pair an LB needs, plus identity."
  def upstream(%{id: _, name: _, host: _} = server) do
    %{
      server_id: server.id,
      server_name: server.name,
      host: server.host,
      port: edge_port(),
      dial: "#{server.host}:#{edge_port()}"
    }
  end

  defp edge_port, do: Application.fetch_env!(:still, :ingress_edge_port)
end
