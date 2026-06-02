defmodule StillWeb.ApiKeysLive do
  @moduledoc """
  The current user's API keys: list, create (the raw key is shown once), and
  revoke. Create and revoke require the `:admin` permission, enforced here as
  well as in the JSON API.
  """

  use StillWeb, :live_view

  import StillWeb.ApiKeyComponents

  alias Still.Accounts
  alias Still.Accounts.ApiKey
  alias Still.Accounts.Scope
  alias Still.Audit.Actor

  @all_permissions ApiKey.valid_permissions()

  @doc "Mounts the API-keys page, loading the current user's keys."
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "API keys")
     |> assign(:can_admin, Scope.can?(socket.assigns.current_scope, :admin))
     |> assign(:all_permissions, @all_permissions)
     |> assign(:create_open, false)
     |> assign(:created, nil)
     |> assign(:selected_permissions, [])
     |> assign(:form_error, nil)
     |> assign(:revoke_target, nil)
     |> assign_form()
     |> load_keys()}
  end

  @doc "Renders the API-keys list and its create / revoke dialogs."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={@nav} active_nav={:api_keys}>
      <.header>
        API keys
        <:subtitle>{length(@keys)} active</:subtitle>
        <:actions>
          <button :if={@can_admin} type="button" class="btn btn-primary btn-sm" phx-click="open_create">
            Create API key
          </button>
        </:actions>
      </.header>

      <.api_keys_table keys={@keys} can_admin={@can_admin} />

      <.api_key_create_dialog
        show={@create_open}
        created={@created}
        form={@form}
        selected_permissions={@selected_permissions}
        all_permissions={@all_permissions}
        form_error={@form_error}
      />

      <.api_key_revoke_dialog target={@revoke_target} />
    </Layouts.app>
    """
  end

  @doc "Handles opening/closing the dialogs, toggling permissions, and create / revoke."
  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:create_open, true)
     |> assign(:created, nil)
     |> assign(:selected_permissions, ["read"])
     |> assign(:form_error, nil)
     |> assign_form()}
  end

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, :create_open, false)}

  def handle_event("toggle_permission", %{"permission" => permission}, socket) do
    {:noreply, update(socket, :selected_permissions, &toggle(&1, permission))}
  end

  def handle_event("create", %{"api_key" => %{"name" => name}}, socket) do
    cond do
      not socket.assigns.can_admin ->
        {:noreply, put_flash(socket, :error, "You don't have permission to create API keys.")}

      socket.assigns.selected_permissions == [] ->
        {:noreply, assign(socket, :form_error, "Pick at least one permission.")}

      true ->
        create_key(socket, name)
    end
  end

  def handle_event("open_revoke", %{"id" => id}, socket) do
    {:noreply, assign(socket, :revoke_target, Enum.find(socket.assigns.keys, &(&1.id == id)))}
  end

  def handle_event("close_revoke", _params, socket),
    do: {:noreply, assign(socket, :revoke_target, nil)}

  def handle_event("revoke", _params, socket) do
    revoke_key(socket, socket.assigns.can_admin, socket.assigns.revoke_target)
  end

  defp create_key(socket, name) do
    attrs = %{"name" => name, "permissions" => socket.assigns.selected_permissions}

    case Accounts.create_api_key(actor(socket), socket.assigns.current_scope.user, attrs) do
      {:ok, api_key} ->
        {:noreply, socket |> assign(:created, api_key) |> assign(:form_error, nil) |> load_keys()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :api_key))}
    end
  end

  defp revoke_key(socket, false, _target),
    do: {:noreply, put_flash(socket, :error, "You don't have permission to revoke API keys.")}

  defp revoke_key(socket, true, nil), do: {:noreply, socket}

  defp revoke_key(socket, true, target) do
    {:ok, _} = Accounts.delete_api_key(actor(socket), target)

    {:noreply,
     socket
     |> assign(:revoke_target, nil)
     |> load_keys()
     |> put_flash(:info, "#{target.name} revoked")}
  end

  defp toggle(permissions, permission) do
    if permission in permissions,
      do: List.delete(permissions, permission),
      else: permissions ++ [permission]
  end

  defp load_keys(socket),
    do: assign(socket, :keys, Accounts.list_api_keys_for(socket.assigns.current_scope.user))

  defp assign_form(socket), do: assign(socket, :form, to_form(%{"name" => ""}, as: :api_key))

  defp actor(socket), do: Actor.from_scope(socket.assigns.current_scope)
end
