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

      <div class="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-4">
        <.stat_card label="Hosts online">
          <span class="inline-flex items-baseline gap-2">
            <span class="text-2xl font-semibold tabular-nums">
              {@connected_count}<span class="text-base text-paper-400 dark:text-ink-500">/{@server_count}</span>
            </span>
            <.status_dot status={
              if @server_count > 0 and @connected_count == @server_count, do: :healthy, else: :warn
            } />
          </span>
        </.stat_card>
        <.stat_card label="Application instances">
          <span class="text-2xl font-semibold tabular-nums">{@apps_running}</span>
        </.stat_card>
        <.stat_card label="Avg CPU">
          <span :if={@avg_cpu} class="text-2xl font-semibold tabular-nums">
            {@avg_cpu}<span class="text-base text-paper-400 dark:text-ink-500">%</span>
          </span>
          <span :if={is_nil(@avg_cpu)} class="text-2xl text-paper-400 dark:text-ink-500">—</span>
          <div :if={@avg_cpu} class="mt-2"><.meter value={@avg_cpu} /></div>
        </.stat_card>
        <.stat_card label="Avg memory">
          <span :if={@avg_mem} class="text-2xl font-semibold tabular-nums">
            {@avg_mem}<span class="text-base text-paper-400 dark:text-ink-500">%</span>
          </span>
          <span :if={is_nil(@avg_mem)} class="text-2xl text-paper-400 dark:text-ink-500">—</span>
          <div :if={@avg_mem} class="mt-2"><.meter value={@avg_mem} /></div>
        </.stat_card>
      </div>

      <section class="mt-8">
        <.section_heading>Hosts</.section_heading>
        <.table
        :if={@servers != []}
        id="servers"
        rows={@servers}
        row_id={fn entry -> "server-#{entry.server.id}" end}
        row_click={fn entry -> JS.navigate(~p"/servers/#{entry.server.id}") end}
      >
        <:col :let={e} label="Name">
          <span class="inline-flex items-center gap-2">
            <.status_dot status={connection_status(e)} />
            <.link navigate={~p"/servers/#{e.server.id}"} class="font-medium hover:underline">
              {e.server.name}
            </.link>
          </span>
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
      </section>
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
    socket |> assign(:servers, Status.servers_with_reports()) |> assign_fleet_stats()
  end

  defp patch_metrics(socket, %{server_id: id} = sample) do
    socket
    |> update(:servers, fn servers ->
      Enum.map(servers, fn
        %{server: %{id: ^id}} = entry -> %{entry | metrics: sample}
        entry -> entry
      end)
    end)
    |> assign_fleet_stats()
  end

  # Fleet roll-up for the summary tiles, recomputed on every structural or
  # metrics change so the tiles track the table.
  defp assign_fleet_stats(socket) do
    servers = socket.assigns.servers
    connected = Enum.filter(servers, &(&1.report != nil))

    socket
    |> assign(:server_count, length(servers))
    |> assign(:connected_count, length(connected))
    |> assign(:apps_running, connected |> Enum.map(&app_count/1) |> Enum.sum())
    |> assign(:avg_cpu, fleet_avg(connected, :cpu_pct))
    |> assign(:avg_mem, fleet_avg(connected, :mem_pct))
  end

  defp fleet_avg(entries, key) do
    case entries |> Enum.map(&metric(&1, key)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      values -> round(Enum.sum(values) / length(values))
    end
  end
end
