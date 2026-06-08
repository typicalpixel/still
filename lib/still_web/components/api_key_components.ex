defmodule StillWeb.ApiKeyComponents do
  @moduledoc """
  Presentation for API keys — the list table and the create / revoke dialogs.
  The dialogs render the shared modal and wire their controls to the
  LiveView's events.
  """

  use StillWeb, :html

  @doc "The API-keys table: name, permissions, last used, created, and a revoke action."
  attr :keys, :list, required: true
  attr :can_admin, :boolean, default: false

  def api_keys_table(assigns) do
    ~H"""
    <.table :if={@keys != []} id="api-keys" rows={@keys} row_id={fn k -> "api-key-#{k.id}" end}>
      <:col :let={k} label="Name"><span class="font-medium">{k.name}</span></:col>
      <:col :let={k} label="ID">
        <span class="font-mono text-[12px] text-paper-500 dark:text-ink-300">
          {String.slice(k.id, 0, 8)}
        </span>
      </:col>
      <:col :let={k} label="Permissions">
        <span class="flex flex-wrap gap-1"><.chip :for={p <- k.permissions}>{p}</.chip></span>
      </:col>
      <:col :let={k} label="Last used">{last_used_label(k)}</:col>
      <:col :let={k} label="Created">{relative_time(k.inserted_at)}</:col>
      <:col :let={k} label="">
        <button
          :if={@can_admin}
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="open_revoke"
          phx-value-id={k.id}
        >
          Revoke
        </button>
      </:col>
    </.table>
    <p :if={@keys == []} class="text-[13px] text-paper-500 dark:text-ink-300">No API keys yet.</p>
    """
  end

  defp last_used_label(%{last_used_at: nil}), do: "never"
  defp last_used_label(%{last_used_at: at}), do: relative_time(at)

  @doc "The create dialog: a name + permissions form, swapping to a one-time key reveal on success."
  attr :show, :boolean, required: true
  attr :created, :any, default: nil, doc: "the created key (with raw_key) once submitted"
  attr :form, :any, required: true
  attr :selected_permissions, :list, required: true
  attr :all_permissions, :list, required: true
  attr :form_error, :string, default: nil

  def api_key_create_dialog(assigns) do
    ~H"""
    <.modal id="create-api-key" show={@show} on_cancel="close_create">
      <:title>{if @created, do: "API key created", else: "Create an API key"}</:title>

      <div :if={@created} class="space-y-3">
        <p class="text-[13px] text-paper-500 dark:text-ink-300">Copy the key now — it will not be shown again.</p>
        <div class="well-surface rounded-lg p-3">
          <div class="mb-1 text-[12px] font-medium text-paper-600 dark:text-ink-200">Raw key</div>
          <div class="select-all break-all font-mono text-sm">{@created.raw_key}</div>
        </div>
        <p class="text-xs text-rust-700 dark:text-rust-300">
          This is the only time we'll show the full key. Store it now.
        </p>
        <div class="modal-action">
          <button type="button" class="btn btn-sm btn-primary" phx-click="close_create">Done</button>
        </div>
      </div>

      <.form :if={!@created} for={@form} id="create-api-key-form" phx-submit="create" class="space-y-3">
        <.input field={@form[:name]} label="Name" placeholder="ci-bot" />

        <div>
          <label class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Permissions</label>
          <div class="flex flex-wrap gap-1">
            <button
              :for={permission <- @all_permissions}
              type="button"
              phx-click="toggle_permission"
              phx-value-permission={permission}
              class={[
                "btn btn-xs",
                if(permission in @selected_permissions, do: "btn-neutral", else: "btn-ghost")
              ]}
            >
              {permission}
            </button>
          </div>
          <p class="mt-1 text-[12px] text-paper-500 dark:text-ink-300">
            <span class="font-mono">admin</span> implies every other permission.
          </p>
          <p :if={@form_error} class="mt-1 text-xs text-rust-700 dark:text-rust-300">{@form_error}</p>
        </div>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_create">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Create key</button>
        </div>
      </.form>
    </.modal>
    """
  end

  @doc "The revoke confirmation dialog for a single key."
  attr :target, :any, default: nil, doc: "the key being revoked, or nil when closed"
  attr :error, :string, default: nil

  def api_key_revoke_dialog(assigns) do
    ~H"""
    <.modal id="revoke-api-key" show={@target != nil} on_cancel="close_revoke">
      <:title>Revoke {@target && @target.name}?</:title>

      <p class="text-sm">
        Anything signed in with this key will start getting 401s on its next request.
      </p>
      <p :if={@error} class="mt-3 text-sm text-rust-700 dark:text-rust-300">{@error}</p>

      <div class="modal-action">
        <button type="button" class="btn btn-sm" phx-click="close_revoke">Cancel</button>
        <button type="button" class="btn btn-sm btn-error" phx-click="revoke">Revoke</button>
      </div>
    </.modal>
    """
  end
end
