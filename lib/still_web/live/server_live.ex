defmodule StillWeb.ServerLive do
  @moduledoc """
  Server detail: connection state, roles, the applications the agent reports
  running on this host, and live CPU/memory/disk utilization.
  """

  use StillWeb, :live_view

  import StillWeb.ServerComponents

  alias Still.Events
  alias Still.Status

  @doc "Mounts the server detail and subscribes to fleet topics."
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Events.subscribe("servers:lobby")
      Events.subscribe("servers:metrics")
    end

    {:ok, socket |> assign(:id, id) |> assign(:page_title, "Server") |> load_server()}
  end

  @doc "Renders the server detail, or a not-found notice."
  @impl true
  def render(%{entry: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:servers}>
      <.header>Server not found</.header>
      <.link navigate={~p"/servers"} class="link text-sm">← Back to servers</.link>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={@nav}
      active_nav={:servers}
      breadcrumbs={[
        %{label: "Servers", navigate: ~p"/servers"},
        %{label: @entry.server.name}
      ]}
    >
      <.header>
        <span class="inline-flex items-center gap-2">
          <.status_dot status={connection_status(@entry)} />
          {@entry.server.name}
        </span>
        <:subtitle>{@entry.server.host} · {connection_line(@entry)}</:subtitle>
      </.header>

      <div class="mb-6 flex flex-wrap gap-1">
        <.chip :for={role <- @entry.server.roles}>{role}</.chip>
      </div>

      <section class="mb-8">
        <.section_heading>Applications running here</.section_heading>
        <.server_apps entry={@entry} />
      </section>

      <section>
        <.section_heading>Resources</.section_heading>
        <.server_resources entry={@entry} />
      </section>
    </Layouts.app>
    """
  end

  @doc "Patches this server's metrics in place; reloads on connect/disconnect."
  @impl true
  def handle_info({:node_metrics, sample}, socket), do: {:noreply, patch_metrics(socket, sample)}
  def handle_info({:server_connected, _payload}, socket), do: {:noreply, load_server(socket)}
  def handle_info({:server_disconnected, _payload}, socket), do: {:noreply, load_server(socket)}

  defp load_server(socket) do
    entry = Enum.find(Status.servers_with_reports(), &(&1.server.id == socket.assigns.id))
    assign(socket, :entry, entry)
  end

  defp patch_metrics(
         %{assigns: %{entry: %{server: %{id: id}} = entry}} = socket,
         %{server_id: id} = sample
       ) do
    assign(socket, :entry, %{entry | metrics: sample})
  end

  defp patch_metrics(socket, _sample), do: socket
end
