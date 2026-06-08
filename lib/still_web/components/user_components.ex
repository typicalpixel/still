defmodule StillWeb.UserComponents do
  @moduledoc """
  Presentation for user administration — the list table and the create / edit /
  reset-password / delete dialogs. The dialogs render the shared modal and wire
  their controls to the LiveView's events.
  """

  use StillWeb, :html

  @doc "The users table: name (flagged when it's you), email, role, created, and row actions."
  attr :users, :list, required: true
  attr :current_user_id, :string, required: true

  def users_table(assigns) do
    ~H"""
    <.table :if={@users != []} id="users" rows={@users} row_id={fn u -> "user-#{u.id}" end}>
      <:col :let={u} label="Name">
        <span class="inline-flex items-center gap-2">
          <span class="font-medium">{u.name}</span>
          <span
            :if={u.id == @current_user_id}
            class="rounded-md bg-paper-200 px-1.5 py-px text-[11px] text-paper-600 dark:bg-ink-700 dark:text-ink-200"
          >
            you
          </span>
        </span>
      </:col>
      <:col :let={u} label="Email"><span class="font-mono text-sm">{u.email}</span></:col>
      <:col :let={u} label="Role"><.chip>{u.role}</.chip></:col>
      <:col :let={u} label="Created">{relative_time(u.inserted_at)}</:col>
      <:col :let={u} label="">
        <div class="flex items-center justify-end gap-1.5">
          <button type="button" class="btn btn-ghost btn-sm" phx-click="open_edit" phx-value-id={u.id}>
            Edit
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="open_reset"
            phx-value-id={u.id}
          >
            Reset password
          </button>
          <button
            :if={u.id != @current_user_id}
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="open_delete"
            phx-value-id={u.id}
          >
            Delete
          </button>
        </div>
      </:col>
    </.table>
    <p :if={@users == []} class="text-[13px] text-paper-500 dark:text-ink-300">No users yet.</p>
    """
  end

  @doc "The create/edit dialog. `editing` is nil for create, or the user being edited."
  attr :show, :boolean, required: true
  attr :editing, :any, default: nil
  attr :form, :any, required: true
  attr :selected_role, :string, required: true
  attr :roles, :list, required: true
  attr :error, :string, default: nil

  def user_form_dialog(assigns) do
    ~H"""
    <.modal id="user-form" show={@show} on_cancel="close_form">
      <:title>{if @editing, do: "Edit #{@editing.email}", else: "Create a user"}</:title>

      <.form for={@form} id="user-form-form" phx-submit="save_user" class="space-y-3">
        <.input field={@form[:name]} label="Name" />
        <.input field={@form[:email]} type="email" label="Email" autocomplete="off" />

        <div>
          <label class="mb-1 block text-[12px] font-medium text-paper-600 dark:text-ink-200">Role</label>
          <div class="flex flex-wrap gap-1">
            <button
              :for={role <- @roles}
              type="button"
              phx-click="select_role"
              phx-value-role={role}
              class={["btn btn-xs", if(role == @selected_role, do: "btn-neutral", else: "btn-ghost")]}
            >
              {role}
            </button>
          </div>
        </div>

        <.input
          :if={!@editing}
          field={@form[:password]}
          type="password"
          label="Initial password"
          autocomplete="new-password"
        />

        <p :if={@error} class="text-xs text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_form">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">
            {if @editing, do: "Save", else: "Create"}
          </button>
        </div>
      </.form>
    </.modal>
    """
  end

  @doc "The reset-password dialog for a single user."
  attr :target, :any, default: nil
  attr :form, :any, required: true
  attr :error, :string, default: nil

  def user_reset_dialog(assigns) do
    ~H"""
    <.modal id="reset-password" show={@target != nil} on_cancel="close_reset">
      <:title>Reset password for {@target && @target.email}</:title>

      <.form for={@form} id="reset-password-form" phx-submit="reset_password" class="space-y-3">
        <.input
          field={@form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
        />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
        />
        <p class="text-[12px] text-paper-500 dark:text-ink-300">This signs them out everywhere they're logged in.</p>
        <p :if={@error} class="text-xs text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_reset">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Reset password</button>
        </div>
      </.form>
    </.modal>
    """
  end

  @doc "The delete-confirmation dialog for a single user."
  attr :target, :any, default: nil
  attr :error, :string, default: nil

  def user_delete_dialog(assigns) do
    ~H"""
    <.modal id="delete-user" show={@target != nil} on_cancel="close_delete">
      <:title>Delete {@target && @target.email}?</:title>

      <p class="text-sm">Their sessions and API keys will stop working immediately.</p>
      <p :if={@error} class="mt-3 text-sm text-rust-700 dark:text-rust-300">{@error}</p>

      <div class="modal-action">
        <button type="button" class="btn btn-sm" phx-click="close_delete">Cancel</button>
        <button type="button" class="btn btn-sm btn-error" phx-click="delete_user">Delete</button>
      </div>
    </.modal>
    """
  end
end
