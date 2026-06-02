defmodule StillWeb.SettingsLive do
  @moduledoc """
  Instance-level settings: a read-only instance summary (host, API version,
  mode, fleet-wide agent version, fleet size), an unwired notifications
  placeholder, the durable audit log (admin only, with preset filters), and an
  unwired danger zone.
  """

  use StillWeb, :live_view

  import StillWeb.AuditComponents

  alias Still.Accounts.Scope
  alias Still.AgentConnectionManager
  alias Still.Audit
  alias Still.Fleet
  alias StillWeb.APIVersion

  @audit_presets [
    {:all, "all"},
    {:applications, "applications"},
    {:servers, "servers"},
    {:users, "users"},
    {:auth, "auth"}
  ]

  @doc "Mounts the settings page, loading the instance summary and (for admins) the audit log."
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:can_admin, Scope.can?(socket.assigns.current_scope, :admin))
     |> assign(:audit_presets, @audit_presets)
     |> assign(:audit_preset, :all)
     |> assign(:expanded, MapSet.new())
     |> load_instance()
     |> load_audit()}
  end

  @doc "Renders the instance, notifications, audit, and danger-zone sections."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:settings}>
      <.header>
        Settings
        <:subtitle>Instance-level configuration for this Still controller.</:subtitle>
      </.header>

      <.panel class="mt-6 mb-6">
        <:title>Instance</:title>
        <:subtitle>
          Identity and topology. Most fields are controller-side config and read-only here.
        </:subtitle>
        <dl class="grid grid-cols-[140px_1fr] items-center gap-x-4 gap-y-4">
          <dt class="text-paper-500 dark:text-ink-300">Host</dt>
          <dd class="font-mono text-paper-800 dark:text-ink-50">{@host}</dd>
          <dt class="text-paper-500 dark:text-ink-300">API version</dt>
          <dd class="font-mono text-paper-800 dark:text-ink-50">{@api_version}</dd>
          <dt class="text-paper-500 dark:text-ink-300">Mode</dt>
          <dd><.chip>{@mode}</.chip></dd>
          <dt class="text-paper-500 dark:text-ink-300">Agent version</dt>
          <dd class="font-mono text-paper-800 dark:text-ink-50">
            {if @agent_version, do: "v#{@agent_version}", else: "—"}
          </dd>
          <dt class="text-paper-500 dark:text-ink-300">Fleet</dt>
          <dd class="font-mono text-paper-500 dark:text-ink-300">
            {@connected_count} of {@server_count} hosts connected
          </dd>
        </dl>
      </.panel>

      <.panel class="mb-6 opacity-70">
        <:title>
          Notifications
          <span class="ml-1 font-mono text-[11px] font-normal text-paper-400 italic dark:text-ink-500">
            · not wired
          </span>
        </:title>
        <:subtitle>Where alerts go. One channel per severity.</:subtitle>
        <dl class="grid grid-cols-[160px_1fr] items-center gap-x-4 gap-y-4">
          <dt class="text-paper-600 dark:text-ink-200">Slack webhook</dt>
          <dd class="font-mono text-[12px] text-paper-400 italic dark:text-ink-500">not configured</dd>
          <dt class="text-paper-600 dark:text-ink-200">Page on failure</dt>
          <dd class="text-[12px] text-paper-400 italic dark:text-ink-500">not configured</dd>
          <dt class="text-paper-600 dark:text-ink-200">Daily digest</dt>
          <dd class="text-[12px] text-paper-400 italic dark:text-ink-500">not configured</dd>
        </dl>
      </.panel>

      <.panel :if={@can_admin} class="mb-6">
        <:title>Audit log</:title>
        <:subtitle>
          Durable record of who did what. Newest first. Per-resource history lives on the
          application and server detail pages.
        </:subtitle>
        <div class="space-y-3">
          <div class="flex flex-wrap items-center gap-1">
            <button
              :for={{value, label} <- @audit_presets}
              type="button"
              phx-click="set_audit_preset"
              phx-value-preset={value}
              class={["btn btn-xs", if(@audit_preset == value, do: "btn-neutral", else: "btn-ghost")]}
            >
              {label}
            </button>
          </div>
          <.audit_log events={@audit_events} expanded={@expanded} />
        </div>
      </.panel>

      <section class="hairline rounded-lg border border-rust-300 dark:border-rust-700/60">
        <div class="border-b border-rust-300 px-6 py-4 dark:border-rust-700/60">
          <div class="text-[13px] font-medium text-rust-700 dark:text-rust-300">Danger zone</div>
          <div class="mt-0.5 text-[11.5px] text-paper-500 dark:text-ink-300">
            Irreversible. Wiring lands with the fleet-control API.
          </div>
        </div>
        <div class="divide-y divide-rust-200 dark:divide-rust-700/40">
          <div class="flex items-center justify-between gap-8 px-6 py-4">
            <div class="min-w-0">
              <div class="text-[13px] text-paper-800 dark:text-ink-50">Drain entire fleet</div>
              <div class="text-[11.5px] text-paper-500 dark:text-ink-300">
                Gracefully stops every app on every host. Existing connections finish.
              </div>
            </div>
            <button type="button" class="btn btn-sm btn-error" disabled>Drain</button>
          </div>
          <div class="flex items-center justify-between gap-8 px-6 py-4">
            <div class="min-w-0">
              <div class="text-[13px] text-paper-800 dark:text-ink-50">Delete everything</div>
              <div class="text-[11.5px] text-paper-500 dark:text-ink-300">
                Removes every application, host registration, deploy log, and API key. Rebootstrap to start over.
              </div>
            </div>
            <button type="button" class="btn btn-sm btn-error" disabled>Delete</button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @doc "Switches the audit preset filter and toggles per-row detail."
  @impl true
  def handle_event("set_audit_preset", %{"preset" => preset}, socket) do
    {:noreply, socket |> assign(:audit_preset, parse_preset(preset)) |> load_audit()}
  end

  def handle_event("toggle_audit", %{"id" => id}, socket) do
    {:noreply, update(socket, :expanded, &toggle_member(&1, id))}
  end

  defp load_instance(socket) do
    servers = Fleet.list_servers()
    connected = Enum.filter(servers, &AgentConnectionManager.connected?(&1.id))

    socket
    |> assign(:host, StillWeb.Endpoint.config(:url)[:host])
    |> assign(:api_version, APIVersion.current())
    |> assign(:server_count, length(servers))
    |> assign(:connected_count, length(connected))
    |> assign(:mode, if(length(servers) <= 1, do: "standalone", else: "multi-node"))
    |> assign(:agent_version, fleet_agent_version(connected))
  end

  defp fleet_agent_version(connected_servers) do
    connected_servers
    |> Enum.map(& &1.metadata["agent_version"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      [one] -> one
      _many -> "mixed"
    end
  end

  defp load_audit(socket) do
    events =
      if socket.assigns.can_admin,
        do: Audit.list(audit_filters(socket.assigns.audit_preset)),
        else: []

    assign(socket, :audit_events, events)
  end

  defp audit_filters(:applications), do: %{subject_type: "application", limit: 100}
  defp audit_filters(:servers), do: %{subject_type: "server", limit: 100}
  defp audit_filters(:users), do: %{subject_type: "user", limit: 100}
  defp audit_filters(:auth), do: %{type: "login_succeeded", limit: 100}
  defp audit_filters(:all), do: %{limit: 100}

  defp parse_preset("applications"), do: :applications
  defp parse_preset("servers"), do: :servers
  defp parse_preset("users"), do: :users
  defp parse_preset("auth"), do: :auth
  defp parse_preset(_all), do: :all

  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end
end
