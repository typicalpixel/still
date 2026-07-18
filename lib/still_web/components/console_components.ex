defmodule StillWeb.ConsoleComponents do
  @moduledoc "Presentation components for the remote console page."

  use StillWeb, :html

  @doc """
  A server selector for applications running on more than one host. Switching
  reattaches the console to the chosen server's active slot.
  """
  attr :targets, :list, required: true
  attr :selected_server_id, :string, required: true

  def server_picker(assigns) do
    ~H"""
    <div class="mb-3 flex flex-wrap gap-1.5">
      <button
        :for={target <- @targets}
        type="button"
        phx-click="select_server"
        phx-value-server_id={target.server_id}
        class={[
          "hairline rounded-md border px-2.5 py-1 text-[12.5px] transition-colors",
          if(target.server_id == @selected_server_id,
            do: "bg-tide-deep/10 font-medium text-tide-deep dark:bg-tide/10 dark:text-tide-bright",
            else: "text-paper-600 hover:bg-paper-200/80 dark:text-ink-200 dark:hover:bg-ink-700/60"
          )
        ]}
      >
        {target.server_name}
        <span class="mono opacity-60">· {target.slot}</span>
      </button>
    </div>
    """
  end

  @doc """
  The terminal window: the xterm mount point plus a status overlay shown
  when the session is not live.
  """
  attr :console_state, :atom, required: true
  attr :console_message, :string, default: nil

  def console_window(assigns) do
    ~H"""
    <div class="code-surface relative overflow-hidden rounded-2xl shadow-[0_30px_80px_-30px_rgba(0,0,0,0.6)] ring-1 ring-white/[0.06]">
      <div class="h-[70dvh] min-h-[24rem] p-3">
        <div id="console-terminal" phx-hook="Console" phx-update="ignore" class="h-full w-full"></div>
      </div>
      <div
        :if={@console_state != :open}
        class="absolute inset-0 flex items-center justify-center bg-black/50"
      >
        <div class="max-w-md rounded-2xl px-6 py-5 text-center code-surface ring-1 ring-white/[0.1]">
          <div :if={@console_state == :connecting} class="text-[13px]">
            Connecting…
          </div>
          <div :if={@console_state in [:closed, :failed]}>
            <div class="text-[13px] font-medium">
              {if @console_state == :failed, do: "Could not attach", else: "Session ended"}
            </div>
            <div :if={@console_message} class="mt-1.5 text-[12.5px] opacity-80">
              {@console_message}
            </div>
            <button type="button" class="btn btn-sm mt-4" phx-click="reconnect">
              Reconnect
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
