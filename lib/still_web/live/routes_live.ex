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
          Routing registry for external load balancers. {@count} {if @count == 1,
            do: "application",
            else: "applications"}.
        </:subtitle>
      </.header>

      <p class="mt-2 mb-6 font-mono text-[11px] text-paper-400 italic dark:text-ink-500">
        Upstreams are not health-filtered — your LB runs its own checks.
      </p>

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
