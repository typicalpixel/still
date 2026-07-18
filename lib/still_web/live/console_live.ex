defmodule StillWeb.ConsoleLive do
  @moduledoc """
  Interactive remote IEx console into a deployed application. Opens a PTY
  session on the application's server via the agent's ConsoleManager and
  bridges bytes between it and the browser terminal.
  """

  use StillWeb, :live_view

  import StillWeb.ConsoleComponents

  alias Still.Agent.ConsoleManager
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Fleet

  @output_tail_bytes 4096

  @doc "Mounts the console for the given application and opens the session once connected."
  @impl true
  def mount(%{"name" => name}, _session, socket) do
    app = Applications.get_application_by_name(name)

    cond do
      app == nil ->
        {:ok, socket |> assign(:name, name) |> assign(:page_title, name) |> assign(:app, nil)}

      app.type != :elixir_release ->
        {:ok,
         socket
         |> put_flash(:error, "Console is only available for Elixir release applications.")
         |> redirect(to: ~p"/applications/#{name}")}

      true ->
        socket =
          socket
          |> assign(:name, name)
          |> assign(:page_title, "#{name} — console")
          |> assign(:app, app)
          |> assign_closed_session()

        socket =
          if connected?(socket) do
            :net_kernel.monitor_nodes(true)
            open_console(socket)
          else
            socket
          end

        {:ok, socket}
    end
  end

  @doc "Renders the console page, or a not-found notice."
  @impl true
  def render(%{app: nil} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={@nav}
      active_nav={:applications}
      breadcrumbs={[%{label: "Applications", navigate: ~p"/applications"}, %{label: "Not found"}]}
    >
      <.header>Application not found</.header>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={@nav}
      active_nav={:applications}
      breadcrumbs={[
        %{label: "Applications", navigate: ~p"/applications"},
        %{label: @app.name, navigate: ~p"/applications/#{@app.name}"},
        %{label: "Console"}
      ]}
    >
      <.header>
        Console
        <:subtitle>
          <span :if={@target} class="inline-flex flex-wrap items-baseline gap-x-5 gap-y-1">
            <span class="inline-flex items-baseline gap-1.5">
              <span class="text-paper-500 dark:text-ink-300">Attached to</span>
              <span class="mono font-medium text-paper-800 dark:text-ink-50">{@target.server_name}</span>
            </span>
            <span class="inline-flex items-baseline gap-1.5">
              <span class="text-paper-500 dark:text-ink-300">Slot</span>
              <span class="mono font-medium text-paper-800 dark:text-ink-50">{@target.slot}</span>
            </span>
            <span :if={@target.version} class="inline-flex items-baseline gap-1.5">
              <span class="text-paper-500 dark:text-ink-300">Version</span>
              <span class="mono font-medium text-paper-800 dark:text-ink-50">{@target.version}</span>
            </span>
          </span>
          <span :if={!@target} class="text-paper-500 dark:text-ink-300">
            No connected server is running this application.
          </span>
        </:subtitle>
        <:actions>
          <button
            :if={@console_state == :open}
            type="button"
            class="btn btn-sm btn-tide"
            phx-click="disconnect"
          >
            Disconnect
          </button>
        </:actions>
      </.header>

      <section class="mt-6">
        <.server_picker
          :if={length(@targets) > 1}
          targets={@targets}
          selected_server_id={@selected_server_id}
        />
        <.console_window console_state={@console_state} console_message={@console_message} />
      </section>
    </Layouts.app>
    """
  end

  @doc "Handles terminal input, resize, and reconnect events from the Console hook."
  @impl true
  def handle_event("input", %{"data" => data}, socket) do
    with %{session_id: sid, target: target} when not is_nil(sid) <- socket.assigns do
      ConsoleManager.input(target.node, sid, data)
    end

    {:noreply, socket}
  end

  def handle_event("resize", %{"cols" => cols, "rows" => rows}, socket) do
    with %{session_id: sid, target: target} when not is_nil(sid) <- socket.assigns do
      ConsoleManager.resize(target.node, sid, rows, cols)
    end

    {:noreply, socket}
  end

  def handle_event("reconnect", _params, socket) do
    {:noreply, open_console(socket)}
  end

  def handle_event("disconnect", _params, socket) do
    {:noreply,
     socket
     |> close_current_session()
     |> assign(:console_state, :closed)
     |> assign(:console_message, "Disconnected.")
     |> push_event("exit", %{})}
  end

  def handle_event("select_server", %{"server_id" => server_id}, socket) do
    if server_id == socket.assigns.selected_server_id do
      {:noreply, socket}
    else
      socket
      |> close_current_session()
      |> assign(:selected_server_id, server_id)
      |> reset_terminal()
      |> open_console()
      |> then(&{:noreply, &1})
    end
  end

  @impl true
  def handle_info({:console_output, sid, data}, %{assigns: %{session_id: sid}} = socket) do
    tail =
      binary_slice(socket.assigns.output_tail <> data, -@output_tail_bytes, @output_tail_bytes)

    {:noreply,
     socket
     |> assign(:output_tail, tail)
     |> push_event("output", %{d: Base.encode64(data)})}
  end

  def handle_info({:console_exit, sid, _status}, %{assigns: %{session_id: sid}} = socket) do
    socket = record_closed(socket)
    failure = attach_failure(socket.assigns.output_tail)

    {:noreply,
     socket
     |> assign(:session_id, nil)
     |> assign(:console_state, if(failure, do: :failed, else: :closed))
     |> assign(:console_message, failure || socket.assigns.console_message)
     |> push_event("exit", %{})}
  end

  def handle_info({:console_timeout, sid, kind}, %{assigns: %{session_id: sid}} = socket) do
    message =
      case kind do
        :idle -> "Session timed out after inactivity."
        :absolute -> "Session reached the maximum duration."
      end

    {:noreply, assign(socket, :console_message, message)}
  end

  def handle_info({:nodedown, node}, socket) do
    case socket.assigns do
      %{session_id: sid, target: %{node: ^node}} when not is_nil(sid) ->
        socket = record_closed(socket)

        {:noreply,
         socket
         |> assign(:session_id, nil)
         |> assign(:console_state, :failed)
         |> assign(:console_message, "The server went away — its agent disconnected.")
         |> push_event("exit", %{})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @doc "Closes the session when the LiveView goes away."
  @impl true
  def terminate(_reason, socket) do
    close_current_session(socket)
    :ok
  end

  # Closes the live session (if any) on the agent and records the audit row.
  # Safe to call when no session is open.
  defp close_current_session(socket) do
    case socket.assigns do
      %{session_id: sid, target: target} when not is_nil(sid) ->
        ConsoleManager.close(target.node, sid)
        record_closed(socket)
        assign(socket, :session_id, nil)

      _ ->
        socket
    end
  end

  defp reset_terminal(socket) do
    socket
    |> assign(:console_state, :connecting)
    |> assign(:console_message, nil)
    |> assign(:output_tail, "")
    |> push_event("reset", %{})
  end

  defp assign_closed_session(socket) do
    socket
    |> assign(:target, nil)
    |> assign(:targets, [])
    |> assign_new(:selected_server_id, fn -> nil end)
    |> assign(:session_id, nil)
    |> assign(:console_state, :connecting)
    |> assign(:console_message, nil)
    |> assign(:output_tail, "")
    |> assign(:opened_at, nil)
  end

  defp open_console(socket) do
    app = socket.assigns.app
    targets = list_targets(app)
    socket = assign(socket, :targets, targets)

    with {:target, %{} = target} <-
           {:target, pick_target(targets, socket.assigns.selected_server_id)},
         {:ok, sid} <-
           ConsoleManager.open(target.node, %{
             application: app.name,
             slot: target.slot,
             exec_command: app.exec_command,
             exec_console: app.exec_console,
             owner: self(),
             user_id: socket.assigns.current_scope.user.id,
             rows: 24,
             cols: 80
           }) do
      Audit.record(actor(socket),
        type: :console_opened,
        subject_type: "application",
        subject_id: app.id,
        payload: %{server: target.server_name, slot: target.slot}
      )

      socket
      |> assign(:target, target)
      |> assign(:selected_server_id, target.server_id)
      |> assign(:session_id, sid)
      |> assign(:console_state, :open)
      |> assign(:console_message, nil)
      |> assign(:output_tail, "")
      |> assign(:opened_at, System.monotonic_time(:second))
      |> push_event("focus", %{})
    else
      {:target, nil} ->
        socket
        |> assign(:console_state, :failed)
        |> assign(:console_message, "No connected server is running this application.")

      {:error, reason} ->
        socket
        |> assign(:console_state, :failed)
        |> assign(:console_message, open_error(reason))
    end
  end

  defp pick_target([], _selected), do: nil

  defp pick_target(targets, selected_server_id) do
    Enum.find(targets, hd(targets), &(&1.server_id == selected_server_id))
  end

  defp list_targets(app) do
    servers_by_id = Map.new(Fleet.list_servers(), &{&1.id, &1})

    app
    |> Applications.list_application_servers()
    |> Enum.flat_map(fn assignment ->
      with report when not is_nil(report) <-
             AgentConnectionManager.get_agent_state(assignment.server_id),
           entry when not is_nil(entry) <-
             Enum.find(report.applications, &(&1.application_name == app.name)) do
        [
          %{
            node: report.node,
            server_id: assignment.server_id,
            server_name: Map.fetch!(servers_by_id, assignment.server_id).name,
            slot: entry.active_slot,
            version: entry.current_version
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp record_closed(socket) do
    %{app: app, target: target, opened_at: opened_at} = socket.assigns

    Audit.record(actor(socket),
      type: :console_closed,
      subject_type: "application",
      subject_id: app.id,
      payload: %{
        server: target.server_name,
        slot: target.slot,
        duration_s: opened_at && System.monotonic_time(:second) - opened_at
      }
    )

    socket
  end

  defp actor(socket), do: Actor.from_scope(socket.assigns.current_scope)

  defp open_error(:not_deployed), do: "This application is not deployed on the selected server."

  defp open_error(:slot_not_active),
    do: "The deployment flipped while connecting. Try again to attach to the new slot."

  defp open_error(:needs_exec_console),
    do:
      "The launch command is too complex to derive a console command from. " <>
        "Set an explicit console command (exec_console) for this application."

  defp open_error(:session_limit),
    do: "You already have the maximum number of console sessions open for this application."

  defp open_error(:agent_session_limit), do: "This server is at its console session limit."

  defp open_error(:rate_limited), do: "Too many console opens — wait a minute and try again."

  defp open_error(other), do: "Could not open a console session: #{inspect(other)}."

  # Classifies `bin/app remote` failure output into actionable messages (the
  # release exits fast when the attach fails; the raw output stays visible in
  # the terminal above this message).
  defp attach_failure(output) do
    cond do
      output =~ "limited shell" ->
        "The remote shell attached without a usable terminal (TERM/terminfo problem on the host)."

      output =~ "Invalid challenge reply" or output =~ "Authentication failed" ->
        "Cookie mismatch — if a secrets launcher injects RELEASE_COOKIE, " <>
          "the console must run through the same launcher."

      output =~ "Could not contact remote node" or output =~ ":nodedown" ->
        "The release is not running with Erlang distribution enabled. " <>
          "Export RELEASE_DISTRIBUTION=name and a per-slot RELEASE_NODE in rel/env.sh.eex."

      true ->
        nil
    end
  end
end
