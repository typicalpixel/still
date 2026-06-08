defmodule StillWeb.RoutesLive do
  @moduledoc """
  Routing registry for external load balancers: one card per application with
  its upstream host:port dials. Reloads on any routing-affecting fleet change.

  Upstreams are not health-filtered — the load balancer runs its own checks.
  """

  use StillWeb, :live_view

  import StillWeb.RouteComponents

  alias Still.Applications
  alias Still.Events
  alias StillWeb.RouteJSON

  @doc "Mounts the routing registry and subscribes to fleet changes."
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe("fleet:changes")
    {:ok, socket |> assign(:page_title, "Routes") |> load_routes()}
  end

  @doc "Renders the routing registry."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:routes}>
      <.header>
        Routes
        <:subtitle>
          Upstream host:port dials per application — only needed if you bring your own load balancer.
        </:subtitle>
      </.header>

      <div class="mt-4 mb-6 flex items-start gap-2.5 rounded-xl bg-tide-deep/8 px-4 py-3 text-[12.5px] text-paper-600 dark:bg-tide/10 dark:text-ink-200">
        <.icon name="hero-information-circle" class="mt-px size-4 shrink-0 text-tide-deep dark:text-tide" />
        <p>
          Most setups don't need this. Still routes traffic through Caddy out of the box — this page
          is only for putting your own load balancer in front of the fleet. Upstreams aren't
          health-filtered; your load balancer runs its own checks. <span class="text-paper-500 dark:text-ink-300">{@count} {if @count == 1, do: "application", else: "applications"}.</span>
        </p>
      </div>

      <.routes_list routes={@routes} />
    </Layouts.app>
    """
  end

  @doc "Reloads the registry whenever the fleet or an application changes."
  @impl true
  def handle_info(:fleet_changed, socket), do: {:noreply, load_routes(socket)}

  defp load_routes(socket) do
    routes = Enum.map(Applications.list_routes(), &RouteJSON.route/1)

    socket
    |> assign(:routes, routes)
    |> assign(:count, length(routes))
  end
end
