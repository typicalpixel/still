defmodule StillWeb.ServersLive do
  @moduledoc """
  Fleet server list: connection status, host, roles, live CPU/memory/disk
  utilization, and assigned-app count. Rows link to the server detail.
  """

  use StillWeb, :live_view

  import StillWeb.ServerComponents

  alias Still.Events
  alias Still.Status

  @doc "Mounts the server list and subscribes to fleet topics."
  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe("servers:lobby")
      Events.subscribe("servers:metrics")
      Events.subscribe("fleet:changes")
    end

    {:ok, socket |> assign(:page_title, "Servers") |> load_servers()}
  end

  @doc "Renders the server list."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:servers}>
      <.header>
        Servers
        <:subtitle>{@server_count} hosts · {@connected_count} connected</:subtitle>
      </.header>

      <.table
        :if={@servers != []}
        id="servers"
        rows={@servers}
        row_id={fn entry -> "server-#{entry.server.id}" end}
      >
        <:col :let={e} label="Status"><.status_dot status={connection_status(e)} /></:col>
        <:col :let={e} label="Name">
          <.link navigate={~p"/servers/#{e.server.id}"} class="font-medium hover:underline">
            {e.server.name}
          </.link>
        </:col>
        <:col :let={e} label="Host">{e.server.host}</:col>
        <:col :let={e} label="Roles">
          <span class="flex flex-wrap gap-1">
            <.chip :for={role <- e.server.roles}>{role}</.chip>
          </span>
        </:col>
        <:col :let={e} label="CPU"><.metric_bar value={metric(e, :cpu_pct)} /></:col>
        <:col :let={e} label="Memory"><.metric_bar value={metric(e, :mem_pct)} /></:col>
        <:col :let={e} label="Disk"><.metric_bar value={metric(e, :disk_pct)} /></:col>
        <:col :let={e} label="Apps">{app_count(e)}</:col>
      </.table>
      <p :if={@servers == []} class="text-[13px] text-paper-500 dark:text-ink-300">
        No servers registered yet.
      </p>
    </Layouts.app>
    """
  end

  @doc "Patches metrics in place; reloads only on structural fleet changes."
  @impl true
  def handle_info({:node_metrics, sample}, socket), do: {:noreply, patch_metrics(socket, sample)}
  def handle_info({:server_connected, _payload}, socket), do: {:noreply, load_servers(socket)}
  def handle_info({:server_disconnected, _payload}, socket), do: {:noreply, load_servers(socket)}
  def handle_info(:fleet_changed, socket), do: {:noreply, load_servers(socket)}

  defp load_servers(socket) do
    servers = Status.servers_with_reports()

    socket
    |> assign(:servers, servers)
    |> assign(:server_count, length(servers))
    |> assign(:connected_count, Enum.count(servers, &(&1.report != nil)))
  end

  defp patch_metrics(socket, %{server_id: id} = sample) do
    update(socket, :servers, fn servers ->
      Enum.map(servers, fn
        %{server: %{id: ^id}} = entry -> %{entry | metrics: sample}
        entry -> entry
      end)
    end)
  end
end
