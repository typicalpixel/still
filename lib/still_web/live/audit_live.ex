defmodule StillWeb.AuditLive do
  @moduledoc """
  The full durable audit log — preset filters and cursor pagination over the
  whole history. Admin only; linked from Settings, not the sidebar.
  """

  use StillWeb, :live_view

  import StillWeb.AuditComponents

  alias Still.Accounts.Scope
  alias Still.Audit

  @presets [
    {:all, "All"},
    {:applications, "Applications"},
    {:servers, "Servers"},
    {:users, "Users"},
    {:auth, "Auth"}
  ]
  @page 25

  @doc "Mounts the audit log for admins, loading the first page; others are redirected home."
  @impl true
  def mount(_params, _session, socket) do
    if Scope.can?(socket.assigns.current_scope, :admin) do
      {:ok,
       socket
       |> assign(:page_title, "Audit log")
       |> assign(:presets, @presets)
       |> assign(:preset, :all)
       |> assign(:expanded, MapSet.new())
       |> load_page(:reset)}
    else
      {:ok, socket |> put_flash(:error, "Admin access required.") |> redirect(to: ~p"/")}
    end
  end

  @doc "Renders the filterable, paginated audit log."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={@nav}
      active_nav={:settings}
      breadcrumbs={[%{label: "Settings", navigate: ~p"/settings"}, %{label: "Audit log"}]}
    >
      <.header>
        Audit log
        <:subtitle>Durable record of who did what across this controller. Newest first.</:subtitle>
      </.header>

      <div class="mt-6 space-y-3">
        <div class="flex flex-wrap items-center gap-1">
          <button
            :for={{value, label} <- @presets}
            type="button"
            phx-click="set_preset"
            phx-value-preset={value}
            class={["btn btn-xs", if(@preset == value, do: "btn-neutral", else: "btn-ghost")]}
          >
            {label}
          </button>
        </div>

        <.audit_log events={@events} expanded={@expanded} empty="No audit events match this filter." />

        <div class="flex justify-center pt-1">
          <button :if={@more?} type="button" class="btn btn-sm" phx-click="load_more">
            Load more
          </button>
          <span
            :if={not @more? and @events != []}
            class="font-mono text-[11px] text-paper-400 italic dark:text-ink-500"
          >
            End of log
          </span>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc "Switches the preset filter (resetting to the first page) and toggles per-row detail."
  @impl true
  def handle_event("set_preset", %{"preset" => preset}, socket) do
    {:noreply,
     socket
     |> assign(:preset, parse_preset(preset))
     |> assign(:expanded, MapSet.new())
     |> load_page(:reset)}
  end

  def handle_event("load_more", _params, socket), do: {:noreply, load_page(socket, :append)}

  def handle_event("toggle_audit", %{"id" => id}, socket) do
    {:noreply, update(socket, :expanded, &toggle_member(&1, id))}
  end

  defp load_page(socket, mode) do
    existing = if mode == :append, do: socket.assigns.events, else: []
    until = existing |> List.last() |> cursor()
    batch = Audit.list(filters(socket.assigns.preset, until))

    socket
    |> assign(:events, Enum.uniq_by(existing ++ batch, & &1.id))
    |> assign(:more?, length(batch) == @page)
  end

  defp cursor(nil), do: nil
  defp cursor(%{inserted_at: at}), do: at

  defp filters(preset, until) do
    preset |> base_filter() |> Map.put(:limit, @page) |> put_until(until)
  end

  defp put_until(filters, nil), do: filters
  defp put_until(filters, until), do: Map.put(filters, :until, until)

  defp base_filter(:applications), do: %{subject_type: "application"}
  defp base_filter(:servers), do: %{subject_type: "server"}
  defp base_filter(:users), do: %{subject_type: "user"}
  defp base_filter(:auth), do: %{type: "login_succeeded"}
  defp base_filter(_all), do: %{}

  defp parse_preset("applications"), do: :applications
  defp parse_preset("servers"), do: :servers
  defp parse_preset("users"), do: :users
  defp parse_preset("auth"), do: :auth
  defp parse_preset(_all), do: :all

  defp toggle_member(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end
end
