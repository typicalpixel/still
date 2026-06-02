defmodule StillWeb.DashboardLive do
  @moduledoc """
  Fleet dashboard: the applications table (health, common version, live hosts,
  24h traffic), the recent-activity stream, and a fleet-online summary. Reloads
  the apps view on deploy/health/fleet changes and the fleet count on
  connect/disconnect; prepends activity events as they arrive.
  """

  use StillWeb, :live_view

  import StillWeb.ApplicationComponents

  alias Still.Deployments
  alias Still.EventLog
  alias Still.Events
  alias Still.Fleet
  alias Still.Status

  @activity_limit 8
  # Pull a wider window than we show so dropped per-step pings still leave
  # @activity_limit meaningful rows.
  @log_window 50

  @doc "Mounts the dashboard, loading apps/fleet/activity and subscribing to live topics."
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe("events:lobby")
      Events.subscribe("servers:lobby")
      Events.subscribe("fleet:changes")
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> load_apps()
     |> load_overview()
     |> load_servers()
     |> load_activity()}
  end

  @doc "Renders the dashboard."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:dashboard}>
      <.header>
        Dashboard
        <:subtitle>
          {length(@apps)} applications on {@overview.server_count} hosts · last event {relative_time(
            @last_event_at
          )}
        </:subtitle>
      </.header>

      <section class="mt-4">
        <.section_heading>
          Applications
          <:actions>
            <span class="text-[11.5px] text-paper-500 dark:text-ink-300">
              sorted by recent activity
            </span>
          </:actions>
        </.section_heading>
        <.app_table apps={@apps} />
      </section>

      <section class="mt-8">
        <.section_heading>
          Recent activity
          <:actions>
            <.arrow_link navigate={~p"/events"}>View all</.arrow_link>
          </:actions>
        </.section_heading>
        <.activity_feed activities={@activity} />
      </section>

      <div class="mt-6 flex items-center gap-2 text-[13px] text-paper-500 dark:text-ink-300">
        <.status_dot status={
          if @overview.connected_server_count == @overview.server_count, do: :healthy, else: :warn
        } />
        <span>{@overview.connected_server_count} of {@overview.server_count} servers online</span>
        <.arrow_link navigate={~p"/servers"} class="ml-auto">Servers</.arrow_link>
      </div>
    </Layouts.app>
    """
  end

  @doc "Prepends arriving events; reloads apps on deploy/health/fleet changes; tracks the fleet count."
  @impl true
  def handle_info({:event_recorded, event}, socket) do
    socket = prepend_activity(socket, event)

    {:noreply,
     if(event.type in [:deployment_updated, :health_transition],
       do: load_apps(socket),
       else: socket
     )}
  end

  def handle_info({:server_connected, _payload}, socket), do: {:noreply, load_overview(socket)}
  def handle_info({:server_disconnected, _payload}, socket), do: {:noreply, load_overview(socket)}

  def handle_info(:fleet_changed, socket),
    do: {:noreply, socket |> load_apps() |> load_overview() |> load_servers()}

  defp load_apps(socket) do
    recent = recent_deploy_times()

    apps =
      Status.applications_with_reports()
      |> Enum.sort_by(&deploy_key(&1, recent), {:desc, NaiveDateTime})

    assign(socket, :apps, apps)
  end

  defp recent_deploy_times do
    %{limit: 50}
    |> Deployments.list_deployments()
    |> Enum.reduce(%{}, fn d, acc -> Map.put_new(acc, d.application.name, d.inserted_at) end)
  end

  defp deploy_key(entry, recent),
    do: Map.get(recent, entry.application.name) || ~N[1970-01-01 00:00:00]

  defp load_overview(socket), do: assign(socket, :overview, Status.overview())

  defp load_servers(socket),
    do: assign(socket, :server_names, Map.new(Fleet.list_servers(), &{&1.id, &1.name}))

  defp load_activity(socket) do
    activities =
      EventLog.list(limit: @log_window)
      |> Enum.map(&event_activity(&1, socket.assigns.server_names))
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@activity_limit)

    assign_activity(socket, activities)
  end

  defp prepend_activity(socket, event) do
    case event_activity(event, socket.assigns.server_names) do
      nil ->
        socket

      activity ->
        assign_activity(socket, Enum.take([activity | socket.assigns.activity], @activity_limit))
    end
  end

  defp assign_activity(socket, activities) do
    socket
    |> assign(:activity, activities)
    |> assign(:last_event_at, activities |> List.first() |> activity_at())
  end

  defp activity_at(nil), do: nil
  defp activity_at(%{at: at}), do: at
end
