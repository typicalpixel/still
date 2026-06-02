defmodule StillWeb.AccountComponents do
  @moduledoc """
  Presentation for the account page — the profile / password / appearance cards
  and the profile-edit and password-change dialogs.
  """

  use StillWeb, :html

  @doc "The profile card: the signed-in user's name, email, role, and id, with an edit action."
  attr :user, :map, required: true

  def profile_card(assigns) do
    ~H"""
    <.panel class="mb-6">
      <:title>Profile</:title>
      <:subtitle>Your user info on this Still instance.</:subtitle>
      <:actions>
        <button type="button" class="btn btn-sm" phx-click="open_profile">Edit</button>
      </:actions>

      <dl class="grid grid-cols-[120px_1fr] gap-x-4 gap-y-4">
        <dt class="text-paper-500 dark:text-ink-300">Name</dt>
        <dd class="text-paper-800 dark:text-ink-50">{@user.name}</dd>
        <dt class="text-paper-500 dark:text-ink-300">Email</dt>
        <dd class="mono text-paper-800 dark:text-ink-50">{@user.email}</dd>
        <dt class="text-paper-500 dark:text-ink-300">Role</dt>
        <dd class="text-paper-800 capitalize dark:text-ink-50">{@user.role}</dd>
        <dt class="text-paper-500 dark:text-ink-300">User ID</dt>
        <dd class="mono text-[12px] text-paper-500 dark:text-ink-300">{@user.id}</dd>
      </dl>
    </.panel>
    """
  end

  @doc "The password card: a prompt to rotate the current user's password."
  def password_card(assigns) do
    ~H"""
    <.panel class="mb-6">
      <:title>Password</:title>
      <:subtitle>Rotate your password. Requires the current one.</:subtitle>
      <:actions>
        <button type="button" class="btn btn-sm" phx-click="open_password">Change</button>
      </:actions>

      <p class="text-[12.5px] text-paper-500 dark:text-ink-300">
        Changing your password signs you out everywhere, including this session — you'll sign back in with the new one.
      </p>
    </.panel>
    """
  end

  @doc "The appearance card: a light/dark/system theme switch for this browser."
  def appearance_card(assigns) do
    ~H"""
    <.panel>
      <:title>Appearance</:title>
      <:subtitle>Theme applies to this browser only. "System" follows your OS preference.</:subtitle>

      <div class="mb-2 text-[11.5px] tracking-[0.08em] text-paper-500 uppercase dark:text-ink-300">
        Theme
      </div>
      <div
        id="theme-switch"
        phx-hook="ThemeSwitch"
        role="radiogroup"
        aria-label="Theme"
        class="hairline inline-flex overflow-hidden rounded-md border"
      >
        <.theme_option value="light" label="Light" first />
        <.theme_option value="dark" label="Dark" />
        <.theme_option value="system" label="System" />
      </div>
    </.panel>
    """
  end

  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :first, :boolean, default: false

  defp theme_option(assigns) do
    ~H"""
    <button
      type="button"
      role="radio"
      aria-checked="false"
      data-phx-theme={@value}
      phx-click={JS.dispatch("phx:set-theme")}
      class={[
        "cursor-pointer px-4 py-1.5 text-[12.5px] text-paper-600 transition-colors",
        "hover:bg-paper-100 dark:text-ink-200 dark:hover:bg-ink-700",
        "aria-checked:bg-paper-800 aria-checked:text-paper-50",
        "dark:aria-checked:bg-ink-50 dark:aria-checked:text-ink-900",
        !@first && "hairline border-l"
      ]}
    >
      {@label}
    </button>
    """
  end

  @doc "The profile-edit dialog (display name only)."
  attr :show, :boolean, required: true
  attr :form, :any, required: true
  attr :error, :string, default: nil

  def profile_dialog(assigns) do
    ~H"""
    <.modal id="edit-profile" show={@show} on_cancel="close_profile">
      <:title>Edit profile</:title>

      <.form for={@form} id="profile-form" phx-submit="save_profile" class="space-y-3">
        <.input field={@form[:name]} label="Name" />
        <p class="text-[12.5px] text-paper-500 dark:text-ink-300">Email and role have separate flows.</p>
        <p :if={@error} class="text-[12px] text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_profile">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Save</button>
        </div>
      </.form>
    </.modal>
    """
  end

  @doc "The password-change dialog (current + new + confirmation)."
  attr :show, :boolean, required: true
  attr :form, :any, required: true
  attr :error, :string, default: nil

  def password_dialog(assigns) do
    ~H"""
    <.modal id="change-password" show={@show} on_cancel="close_password">
      <:title>Change password</:title>

      <.form for={@form} id="password-form" phx-submit="change_password" class="space-y-3">
        <.input
          field={@form[:current_password]}
          type="password"
          label="Current password"
          autocomplete="current-password"
        />
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
        <p class="text-[12.5px] text-paper-500 dark:text-ink-300">
          This signs you out everywhere — sign back in afterwards.
        </p>
        <p :if={@error} class="text-[12px] text-rust-700 dark:text-rust-300">{@error}</p>

        <div class="modal-action">
          <button type="button" class="btn btn-sm" phx-click="close_password">Cancel</button>
          <button type="submit" class="btn btn-sm btn-primary">Update password</button>
        </div>
      </.form>
    </.modal>
    """
  end
end
