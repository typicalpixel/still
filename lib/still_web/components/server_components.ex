defmodule StillWeb.ServerComponents do
  @moduledoc """
  Presentation for the server / fleet pages — connection-state derivations
  and the detail sections. Imported by the server LiveViews, not globally.
  """

  use StillWeb, :html

  @doc """
  Maps a fleet entry (`%{server, report, metrics}`) to a connection status
  atom for `StillWeb.DashboardComponents.status_dot/1`. An entry is connected
  when its agent has reported live state (`report` is present).
  """
  def connection_status(%{report: nil}), do: :disconnected
  def connection_status(_entry), do: :connected

  @doc "One-line connection summary: when it connected, or when last seen."
  def connection_line(%{report: %{connected_at: at}}), do: "Connected #{relative_time(at)}"
  def connection_line(%{server: %{last_seen_at: nil}}), do: "Never connected"
  def connection_line(%{server: %{last_seen_at: at}}), do: "Last seen #{relative_time(at)}"

  @doc "A utilization percentage for the entry, or nil when disconnected / no sample."
  def metric(%{report: nil}, _key), do: nil
  def metric(%{metrics: nil}, _key), do: nil
  def metric(%{metrics: metrics}, key) when is_atom(key), do: Map.get(metrics, key)

  @doc "Count of applications the agent reports running on this host."
  def app_count(entry) when is_map(entry), do: length(apps(entry))

  @doc "Status-dot tone for one application slot on a server (ports serverSlotDot)."
  def server_slot_dot(%{connected: false}), do: :neutral
  def server_slot_dot(%{health: :degraded}), do: :warn
  def server_slot_dot(%{health: :unhealthy}), do: :danger
  def server_slot_dot(%{health: :healthy}), do: :healthy

  def server_slot_dot(%{current_version: version}),
    do: if(deployed?(version), do: :healthy, else: :neutral)

  @doc "Label for one application slot on a server (ports serverSlotLabel)."
  def server_slot_label(%{connected: false}), do: "unreachable"
  def server_slot_label(%{health: health}) when not is_nil(health), do: to_string(health)

  def server_slot_label(%{current_version: version}),
    do: if(deployed?(version), do: "running", else: "not deployed")

  defp deployed?(version), do: not is_nil(version) and version != "—"

  @doc """
  The fleet table for an application detail page — the servers it's assigned
  to, with desired/current version (and a drift flag), per-slot health, and
  last-seen time. Rows link to the server detail.
  """
  attr :fleet, :list, required: true
  attr :can_admin, :boolean, default: false

  def app_fleet(assigns) do
    ~H"""
    <.table :if={@fleet != []} id="fleet" rows={@fleet} row_id={fn r -> "slot-#{r.server_id}" end}>
      <:col :let={r} label="Host">
        <.link
          navigate={~p"/servers/#{r.server_id}"}
          class="font-medium text-paper-900 hover:underline dark:text-ink-50"
        >
          {r.server_name}
        </.link>
        <div class="text-[11.5px] text-paper-500 dark:text-ink-300">{r.host}</div>
      </:col>
      <:col :let={r} label="Desired"><.chip>{r.desired_version}</.chip></:col>
      <:col :let={r} label="Current">
        <span class="inline-flex items-center gap-1.5">
          <.chip>{r.current_version}</.chip>
          <span :if={drift?(r)} class="text-[11px] text-orange-600 dark:text-orange-400">drift</span>
        </span>
      </:col>
      <:col :let={r} label="Health">
        <span class="inline-flex items-center gap-2">
          <.status_dot status={server_slot_dot(r)} />{server_slot_label(r)}
        </span>
      </:col>
      <:col :let={r} label="Last seen">{relative_time(r.last_seen)}</:col>
      <:col :let={r} :if={@can_admin} label="">
        <button
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="open_unassign"
          phx-value-id={r.assignment_id}
          phx-value-name={r.server_name}
        >
          Unassign
        </button>
      </:col>
    </.table>
    <p :if={@fleet == []} class="text-[13px] text-paper-500 dark:text-ink-300">No servers assigned.</p>
    """
  end

  defp drift?(r), do: r.current_version != r.desired_version and r.current_version != "—"

  @doc "Lists the applications the agent reports running on a host."
  attr :entry, :map, required: true

  def server_apps(assigns) do
    ~H"""
    <ul :if={apps(@entry) != []} class="space-y-1">
      <li
        :for={app <- apps(@entry)}
        id={"app-#{app.application_name}"}
        class="flex flex-wrap items-center gap-2 text-[13px]"
      >
        <.status_dot status={app.health || :unknown} />
        <.link
          navigate={~p"/applications/#{app.application_name}"}
          class="font-medium text-paper-900 hover:underline dark:text-ink-50"
        >
          {app.application_name}
        </.link>
        <.chip>{app.current_version || "—"}</.chip>
        <.chip>slot {app.active_slot || "—"}</.chip>
        <span :if={app.active_port} class="font-mono text-[12px] text-paper-500 dark:text-ink-300">
          :{app.active_port}
        </span>
      </li>
    </ul>
    <p :if={apps(@entry) == []} class="text-[13px] text-paper-500 dark:text-ink-300">
      No applications assigned.
    </p>
    """
  end

  @doc "CPU / memory / disk utilization tiles for a host."
  attr :entry, :map, required: true

  def server_resources(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
      <.stat_card :for={resource <- resources(@entry)} label={resource.label}>
        <div class="text-3xl font-semibold tabular-nums">
          <span :if={resource.pct}>
            {resource.pct}<span class="text-base text-paper-400 dark:text-ink-500">%</span>
          </span>
          <span :if={is_nil(resource.pct)} class="text-paper-400 dark:text-ink-500">—</span>
        </div>
        <div :if={resource.pct} class="mt-3"><.meter value={resource.pct} /></div>
      </.stat_card>
    </div>
    """
  end

  defp apps(%{report: nil}), do: []
  defp apps(%{report: report}), do: report.applications

  defp resources(entry) do
    [
      %{label: "CPU", pct: metric(entry, :cpu_pct)},
      %{label: "Memory", pct: metric(entry, :mem_pct)},
      %{label: "Disk", pct: metric(entry, :disk_pct)}
    ]
  end
end
