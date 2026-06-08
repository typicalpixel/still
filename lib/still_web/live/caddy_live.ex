defmodule StillWeb.CaddyLive do
  @moduledoc """
  Read-only viewer for the live Caddy JSON config running on the controller or
  any connected agent. Admin-only — a dashboard mirror of `GET /api/caddy`, for
  diagnosing why traffic is (or isn't) reaching an app.
  """

  use StillWeb, :live_view

  alias Still.Accounts.Scope
  alias Still.CaddyInspector
  alias Still.Fleet

  @doc "Mounts the viewer, loading the controller's config for admins."
  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, page_title: "Caddy", target: "controller")

    socket =
      if Scope.can?(socket.assigns.current_scope, :admin) do
        servers = Fleet.list_servers()

        socket
        |> assign(:forbidden, false)
        |> assign(:servers, servers)
        |> assign(:multi_node?, length(servers) > 1)
        |> load_config()
      else
        socket
        |> assign(:forbidden, true)
        |> assign(:servers, [])
        |> assign(:multi_node?, false)
        |> assign(:config, nil)
        |> assign(:error, nil)
      end

    {:ok, socket}
  end

  @doc "Renders the node picker and the selected node's Caddy config."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:caddy}>
      <.header>
        Caddy config
        <:subtitle>The live Caddy JSON the selected node is serving.</:subtitle>
      </.header>

      <div
        :if={@forbidden}
        class="mt-6 rounded-lg border border-rust-300 p-4 text-[13px] text-paper-700 dark:border-rust-700/60 dark:text-ink-100"
      >
        Admin permission is required to inspect Caddy configuration.
      </div>

      <div :if={!@forbidden} class="mt-4">
        <form :if={@multi_node?} phx-change="select_target" class="mb-4 flex items-center gap-2">
          <label for="caddy-target" class="text-[12px] text-paper-500 dark:text-ink-300">Node</label>
          <select id="caddy-target" name="target" class="select select-sm">
            <option value="controller" selected={@target == "controller"}>Controller</option>
            <option :for={server <- @servers} value={server.id} selected={@target == server.id}>
              {server.name}
            </option>
          </select>
        </form>

        <div
          :if={@error}
          class="rounded-lg border border-rust-300 p-4 text-[13px] text-paper-700 dark:border-rust-700/60 dark:text-ink-100"
        >
          {error_message(@error)}
        </div>

        <pre
          :if={@config}
          class="code-surface mono overflow-auto rounded-2xl p-4 text-[12px] leading-relaxed ring-1 ring-white/[0.06]"
        ><%= @config %></pre>
      </div>
    </Layouts.app>
    """
  end

  @doc "Switches the inspected node and reloads its config."
  @impl true
  def handle_event("select_target", %{"target" => target}, socket) do
    {:noreply, socket |> assign(:target, target) |> load_config()}
  end

  defp load_config(socket) do
    result =
      case socket.assigns.target do
        "controller" -> CaddyInspector.local_config()
        server_id -> CaddyInspector.config_for_server(server_id)
      end

    case result do
      {:ok, config} ->
        socket |> assign(:config, Jason.encode!(config, pretty: true)) |> assign(:error, nil)

      {:error, reason} ->
        socket |> assign(:config, nil) |> assign(:error, reason)
    end
  end

  defp error_message(:agent_disconnected), do: "That server's agent isn't connected."
  defp error_message(:caddy_unreachable), do: "Couldn't reach Caddy on that node."
end
