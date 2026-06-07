defmodule StillWeb.EventsLive do
  @moduledoc """
  Fleet activity stream — deploy transitions, health transitions, and server
  connect/disconnect, newest first, filterable by type via `?type=`. Live via
  `events:lobby`.

  Best-effort: the underlying log is in-memory, retains roughly the last 24h,
  and is cleared by a controller restart.
  """

  use StillWeb, :live_view

  alias Still.EventLog
  alias Still.Events
  alias Still.Fleet

  @limit 200

  @doc "Mounts the activity stream, loading recent events and subscribing live."
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe("events:lobby")

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:server_names, Map.new(Fleet.list_servers(), &{&1.id, &1.name}))
     |> assign(:events, EventLog.list(limit: @limit))}
  end

  @doc "Applies the `?type=` filter and recomputes the visible rows."
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:type_filter, parse_type(params)) |> recompute()}
  end

  @doc "Renders the activity stream with its type tabs."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:events}>
      <.header>
        Activity
        <:subtitle>showing {length(@activities)} of {@total} most recent events</:subtitle>
      </.header>

      <div class="mt-4 mb-3 flex flex-wrap items-center gap-2">
        <.link
          :for={
            {value, label} <- [
              all: "All",
              deployment: "Deployments",
              health: "Health",
              server: "Servers"
            ]
          }
          patch={filter_path(value)}
          class={["badge", if(@type_filter == value, do: "badge-neutral", else: "badge-ghost")]}
        >
          {label}
        </.link>
      </div>

      <.activity_feed activities={@activities} empty="No events match this filter." />

      <p class="mt-3 font-mono text-[11px] text-paper-400 italic dark:text-ink-500">
        Best-effort, in-memory — kept ~24h and cleared on controller restart. For durable history,
        see the audit log.
      </p>
    </Layouts.app>
    """
  end

  @doc "Prepends arriving events and recomputes the visible rows."
  @impl true
  def handle_info({:event_recorded, event}, socket) do
    {:noreply, socket |> prepend(event) |> recompute()}
  end

  defp prepend(socket, event),
    do: assign(socket, :events, Enum.take([event | socket.assigns.events], @limit))

  defp recompute(socket) do
    activities =
      socket.assigns.events
      |> Enum.filter(&type_match?(&1.type, socket.assigns.type_filter))
      |> Enum.map(&event_activity(&1, socket.assigns.server_names))
      |> Enum.reject(&is_nil/1)

    socket
    |> assign(:activities, activities)
    |> assign(:total, length(socket.assigns.events))
  end

  defp type_match?(_type, :all), do: true
  defp type_match?(:deployment_updated, :deployment), do: true
  defp type_match?(:health_transition, :health), do: true

  defp type_match?(type, :server) when type in [:server_connected, :server_disconnected],
    do: true

  defp type_match?(_type, _filter), do: false

  defp filter_path(:all), do: ~p"/events"
  defp filter_path(type), do: ~p"/events?#{[type: type]}"

  defp parse_type(%{"type" => "deployment"}), do: :deployment
  defp parse_type(%{"type" => "health"}), do: :health
  defp parse_type(%{"type" => "server"}), do: :server
  defp parse_type(_params), do: :all
end
