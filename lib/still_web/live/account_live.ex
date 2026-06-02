defmodule StillWeb.AccountLive do
  @moduledoc """
  The signed-in user's own account: view profile (name/email/role/id), edit the
  display name, change the password (requires the current one), and pick a theme
  for this browser. A password change invalidates every session — including this
  one — so it ends on the login page.
  """

  use StillWeb, :live_view

  import StillWeb.AccountComponents

  alias Still.Accounts
  alias Still.Accounts.Scope
  alias Still.Accounts.User
  alias Still.Audit.Actor
  alias StillWeb.UserAuth

  @doc "Mounts the account page from the current scope."
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Account")
     |> assign(:profile_open, false)
     |> assign(:profile_error, nil)
     |> assign(:password_open, false)
     |> assign(:password_error, nil)
     |> assign_profile_form()
     |> assign_password_form()}
  end

  @doc "Renders the profile, password, and appearance cards and their dialogs."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:account}>
      <.header>Account</.header>

      <div class="mt-6">
        <.profile_card user={@current_scope.user} />
        <.password_card />
        <.appearance_card />
      </div>

      <.profile_dialog show={@profile_open} form={@profile_form} error={@profile_error} />
      <.password_dialog show={@password_open} form={@password_form} error={@password_error} />
    </Layouts.app>
    """
  end

  @doc "Handles the profile-edit and password-change dialogs."
  @impl true
  def handle_event("open_profile", _params, socket) do
    {:noreply,
     socket |> assign(:profile_open, true) |> assign(:profile_error, nil) |> assign_profile_form()}
  end

  def handle_event("close_profile", _params, socket),
    do: {:noreply, assign(socket, :profile_open, false)}

  def handle_event("save_profile", %{"account" => %{"name" => name}}, socket) do
    case Accounts.update_user_profile(actor(socket), current_user(socket), %{"name" => name}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:current_scope, Scope.for_user(updated))
         |> assign(:profile_open, false)
         |> put_flash(:info, "Profile updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, as: :account))}
    end
  end

  def handle_event("open_password", _params, socket) do
    {:noreply,
     socket
     |> assign(:password_open, true)
     |> assign(:password_error, nil)
     |> assign_password_form()}
  end

  def handle_event("close_password", _params, socket),
    do: {:noreply, assign(socket, :password_open, false)}

  def handle_event("change_password", %{"account" => params}, socket),
    do: change_password(socket, params)

  defp change_password(socket, %{"password" => pw, "password_confirmation" => confirm})
       when pw != confirm do
    {:noreply, assign(socket, :password_error, "Passwords must match")}
  end

  defp change_password(socket, %{"current_password" => current} = params) do
    if User.valid_password?(current_user(socket), current) do
      rotate_password(socket, params["password"])
    else
      {:noreply, assign(socket, :password_error, "Current password is incorrect.")}
    end
  end

  defp rotate_password(socket, new_password) do
    case Accounts.update_user_password(actor(socket), current_user(socket), %{
           "password" => new_password
         }) do
      {:ok, {_updated, expired_tokens}} ->
        UserAuth.disconnect_sessions(expired_tokens)

        {:noreply,
         socket
         |> put_flash(:info, "Password updated. Sign in again with your new password.")
         |> redirect(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign(socket, :password_form, to_form(changeset, as: :account))}
    end
  end

  defp assign_profile_form(socket),
    do:
      assign(socket, :profile_form, to_form(%{"name" => current_user(socket).name}, as: :account))

  defp assign_password_form(socket) do
    assign(
      socket,
      :password_form,
      to_form(%{"current_password" => "", "password" => "", "password_confirmation" => ""},
        as: :account
      )
    )
  end

  defp current_user(socket), do: socket.assigns.current_scope.user

  defp actor(socket), do: Actor.from_scope(socket.assigns.current_scope)
end
