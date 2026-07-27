defmodule Still.Ingress do
  @moduledoc """
  Controller-side Caddy routing: one ingress route per assigned
  application, routing the application's domain to all agent hosts
  that run it.

  In multi-node mode the Still controller runs a Caddy instance that
  sits in front of the agent fleet. This module builds the routes
  that Caddy needs — agent-side per-slot routing (blue/green, local
  ports) is handled on the agents themselves by the DeploymentManager
  and is invisible to the ingress layer. All the ingress Caddy cares
  about is "which agents run app X, right now."

  Ingress routes carry an `@id` of `still_ingress_<application>` so
  they never collide with the `still_app_<application>` routes an
  agent-local Caddy would write, and with the `still_controller` /
  `still_catchall` system routes from `Still.CaddyBootstrap`.

  In single-server mode the ingress routes would point right back at
  the same box on :80 — redundant with the agent-local routes the
  DeploymentManager already writes. Callers that build the ingress
  config decide whether to invoke this module; the builder itself
  doesn't know or care about topology.
  """

  alias Still.Caddy.Config, as: CaddyConfig
  alias Still.Caddy.Tracing

  @id_prefix "still_ingress_"

  @doc """
  The `@id` prefix used for every route this module builds. Exposed so
  reconcilers can remove stale ingress routes without second-guessing
  the naming convention.
  """
  def id_prefix, do: @id_prefix

  @doc """
  Returns `true` if the given Caddy route map is an ingress route
  emitted by this module.
  """
  def ingress_route?(%{"@id" => id}) when is_binary(id), do: String.starts_with?(id, @id_prefix)
  def ingress_route?(_), do: false

  @doc """
  Builds the list of ingress route maps from the shape returned by
  `Still.Applications.list_routes/0` — a list of
  `%{application: %Application{}, servers: [%Server{}]}` entries.

  Each entry becomes one Caddy route with:

    * `@id` — `still_ingress_<application_name>`, stable across
      reconciles so upserts-by-id work.
    * `match` — Host (+ optional path prefix), the same shape agents
      use for their local app routes.
    * `handle` — a `reverse_proxy` pointed at every assigned agent on
      the configured `:ingress_edge_port`. Active health checks are
      attached when the application defines a health_check, so Caddy
      takes unresponsive agents out of rotation without help from Still.
      Probes carry the application's domain as their `Host` header so
      they traverse the agent's host-routed Caddy to the app itself.
    * `terminal` — true, so one matched ingress route stops
      evaluation.

  With `caddy_tracing` enabled the handle is preceded by a `tracing`
  handler named after the application.

  Applications with an empty server list are skipped. The caller is
  expected to pre-filter via `Applications.list_routes/0` (which
  already omits unassigned apps), but the guard is here for safety
  in case a caller hands us raw data.
  """
  def build_routes(entries) when is_list(entries) do
    entries
    |> Enum.reject(&empty_server_list?/1)
    |> Enum.map(&build_route/1)
  end

  defp empty_server_list?(%{servers: []}), do: true
  defp empty_server_list?(_), do: false

  defp build_route(%{application: app, servers: servers}) do
    CaddyConfig.route(
      id: @id_prefix <> app.name,
      match: [build_match(app)],
      handle: Tracing.prepend(build_handle(app, servers), app.name),
      terminal: true
    )
  end

  defp build_match(app) do
    path =
      case app.path_prefix do
        nil -> nil
        "" -> nil
        prefix when is_binary(prefix) -> [prefix <> "*"]
      end

    CaddyConfig.match(host: [app.domain], path: path)
  end

  defp build_handle(%{maintenance: true} = app, _servers) do
    [CaddyConfig.maintenance_response(app.maintenance_message)]
  end

  defp build_handle(app, servers) do
    dials = Enum.map(servers, &"#{&1.host}:#{edge_port()}")

    opts =
      [dials: dials]
      |> maybe_put_health_check(app)
      |> maybe_put_lb_policy(app)

    [CaddyConfig.reverse_proxy(opts)]
  end

  defp maybe_put_health_check(opts, %{health_check: nil}), do: opts

  # `host:` makes the probe traverse the agent's host-routed Caddy to the
  # app; `proto: "https"` advertises the edge scheme so force-ssl apps
  # answer 200 instead of redirecting. The proto header only survives on
  # agents that list the controller in trusted_proxies — elsewhere Caddy
  # strips it, which is today's behavior.
  defp maybe_put_health_check(opts, %{health_check: hc} = app) do
    Keyword.put(opts, :health_check, %{
      path: hc.path,
      interval_ms: hc.interval_ms,
      deadline_ms: hc.deadline_ms,
      host: app.domain,
      proto: "https"
    })
  end

  defp maybe_put_lb_policy(opts, %{type: :elixir_release}),
    do: Keyword.put(opts, :lb_policy, :ip_hash)

  defp maybe_put_lb_policy(opts, _app), do: opts

  defp edge_port, do: Application.fetch_env!(:still, :ingress_edge_port)
end
