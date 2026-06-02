defmodule StillWeb.UsersLive do
  @moduledoc """
  User administration (admin only): list, create, edit (name/email/role), reset
  password, and delete. Guards mirror the JSON API — you can't delete your own
  account, and the last admin can't be demoted.
  """

  use StillWeb, :live_view

  import StillWeb.UserComponents

  alias Still.Accounts
  alias Still.Accounts.Scope
  alias Still.Audit.Actor
  alias StillWeb.UserAuth

  @roles ["admin", "deployer", "viewer"]

  @doc "Mounts the users page, loading all users; redirects non-admins to the dashboard."
  @impl true
  def mount(_params, _session, socket) do
    if Scope.can?(socket.assigns.current_scope, :admin) do
      {:ok,
       socket
       |> assign(:page_title, "Users")
       |> assign(:roles, @roles)
       |> assign(:form_open, false)
       |> assign(:editing, nil)
       |> assign(:selected_role, "viewer")
       |> assign(:form_error, nil)
       |> assign(:user_form, new_user_form())
       |> assign(:reset_target, nil)
       |> assign(:reset_error, nil)
       |> assign(:reset_form, reset_form())
       |> assign(:delete_target, nil)
       |> assign(:delete_error, nil)
       |> load_users()}
    else
      {:ok, socket |> put_flash(:error, "Admin access required.") |> redirect(to: ~p"/")}
    end
  end

  @doc "Renders the users list and its create / edit / reset / delete dialogs."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:users}>
      <.header>
        Users
        <:subtitle>{length(@users)} total</:subtitle>
        <:actions>
          <button type="button" class="btn btn-primary btn-sm" phx-click="open_create">
            Create user
          </button>
        </:actions>
      </.header>

      <.users_table users={@users} current_user_id={@current_scope.user.id} />

      <.user_form_dialog
        show={@form_open}
        editing={@editing}
        form={@user_form}
        selected_role={@selected_role}
        roles={@roles}
        error={@form_error}
      />

      <.user_reset_dialog target={@reset_target} form={@reset_form} error={@reset_error} />
      <.user_delete_dialog target={@delete_target} error={@delete_error} />
    </Layouts.app>
    """
  end

  @doc "Handles dialog open/close, role selection, and the create / edit / reset / delete mutations."
  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_open, true)
     |> assign(:editing, nil)
     |> assign(:selected_role, "viewer")
     |> assign(:form_error, nil)
     |> assign(:user_form, new_user_form())}
  end

  def handle_event("open_edit", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    {:noreply,
     socket
     |> assign(:form_open, true)
     |> assign(:editing, user)
     |> assign(:selected_role, to_string(user.role))
     |> assign(:form_error, nil)
     |> assign(:user_form, to_form(%{"name" => user.name, "email" => user.email}, as: :user))}
  end

  def handle_event("close_form", _params, socket),
    do: {:noreply, assign(socket, :form_open, false)}

  def handle_event("select_role", %{"role" => role}, socket),
    do: {:noreply, assign(socket, :selected_role, role)}

  def handle_event("save_user", %{"user" => params}, socket) do
    attrs = Map.put(params, "role", socket.assigns.selected_role)

    case socket.assigns.editing do
      nil -> save_new(socket, attrs)
      user -> save_edit(socket, user, attrs)
    end
  end

  def handle_event("open_reset", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:reset_target, Accounts.get_user!(id))
     |> assign(:reset_error, nil)
     |> assign(:reset_form, reset_form())}
  end

  def handle_event("close_reset", _params, socket),
    do: {:noreply, assign(socket, :reset_target, nil)}

  def handle_event("reset_password", %{"user" => params}, socket),
    do: reset_password(socket, params)

  def handle_event("open_delete", %{"id" => id}, socket) do
    {:noreply,
     socket |> assign(:delete_target, Accounts.get_user!(id)) |> assign(:delete_error, nil)}
  end

  def handle_event("close_delete", _params, socket),
    do: {:noreply, assign(socket, :delete_target, nil)}

  def handle_event("delete_user", _params, socket) do
    case Accounts.delete_user(actor(socket), socket.assigns.delete_target) do
      {:ok, deleted} ->
        {:noreply,
         socket
         |> assign(:delete_target, nil)
         |> load_users()
         |> put_flash(:info, "#{deleted.email} deleted")}

      {:error, :cannot_delete_self} ->
        {:noreply, assign(socket, :delete_error, "You cannot delete your own account")}
    end
  end

  defp save_new(socket, attrs) do
    case Accounts.create_user(actor(socket), attrs) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:form_open, false)
         |> load_users()
         |> put_flash(:info, "#{user.email} created")}

      {:error, changeset} ->
        {:noreply, assign(socket, :user_form, to_form(changeset, as: :user))}
    end
  end

  defp save_edit(socket, user, attrs) do
    case Accounts.update_user(actor(socket), user, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:form_open, false)
         |> load_users()
         |> put_flash(:info, "#{updated.email} updated")}

      {:error, :last_admin} ->
        {:noreply, assign(socket, :form_error, "Refusing to remove the last admin")}

      {:error, changeset} ->
        {:noreply, assign(socket, :user_form, to_form(changeset, as: :user))}
    end
  end

  defp reset_password(socket, %{"password" => pw, "password_confirmation" => confirm})
       when pw != confirm do
    {:noreply, assign(socket, :reset_error, "Passwords must match")}
  end

  defp reset_password(socket, %{"password" => pw}) do
    case Accounts.update_user_password(actor(socket), socket.assigns.reset_target, %{
           "password" => pw
         }) do
      {:ok, {user, expired_tokens}} ->
        UserAuth.disconnect_sessions(expired_tokens)

        {:noreply,
         socket |> assign(:reset_target, nil) |> put_flash(:info, "#{user.email} password reset")}

      {:error, changeset} ->
        {:noreply, assign(socket, :reset_form, to_form(changeset, as: :user))}
    end
  end

  defp load_users(socket), do: assign(socket, :users, Accounts.list_users())

  defp new_user_form, do: to_form(%{"name" => "", "email" => "", "password" => ""}, as: :user)

  defp reset_form, do: to_form(%{"password" => "", "password_confirmation" => ""}, as: :user)

  defp actor(socket), do: Actor.from_scope(socket.assigns.current_scope)
end
