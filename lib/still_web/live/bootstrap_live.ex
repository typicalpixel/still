defmodule StillWeb.BootstrapLive do
  @moduledoc """
  First-run setup: when the instance has no users, creates the first admin and
  signs them straight in (the form posts the new credentials to the session
  controller). Redirects to the login page once any user exists.
  """

  use StillWeb, :live_view

  alias Still.Accounts
  alias Still.Audit.Actor

  @doc "Mounts the setup form, or redirects to login if the instance is already set up."
  @impl true
  def mount(_params, _session, socket) do
    if Accounts.has_users?() do
      {:ok,
       socket
       |> put_flash(:info, "This instance is already set up. Sign in to continue.")
       |> redirect(to: ~p"/users/log-in")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Set up Still")
       |> assign(:error, nil)
       |> assign(:trigger_submit, false)
       |> assign_form()}
    end
  end

  @doc "Renders the first-admin setup form."
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-4">
        <.header>
          Set up Still
          <:subtitle>Create the first admin account. You can add more users later.</:subtitle>
        </.header>

        <.form
          :let={f}
          for={@form}
          id="bootstrap-form"
          action={~p"/users/log-in"}
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="email"
            required
            phx-mounted={JS.focus()}
          />
          <.input field={f[:name]} type="text" label="Name" autocomplete="name" required />
          <.input
            field={f[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
          />
          <.input
            field={f[:password_confirmation]}
            type="password"
            label="Confirm password"
            autocomplete="new-password"
            required
          />
          <p :if={@error} class="text-[13px] text-rust-700 dark:text-rust-300">{@error}</p>
          <.button class="btn btn-primary w-full" phx-disable-with="Creating…">
            Create admin account <span aria-hidden="true">→</span>
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @doc "Creates the first admin, then triggers the login POST to sign them in."
  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    if params["password"] != params["password_confirmation"] do
      {:noreply, assign(socket, :error, "Passwords must match")}
    else
      create_admin(socket, params)
    end
  end

  defp create_admin(socket, params) do
    attrs = params |> Map.take(["email", "name", "password"]) |> Map.put("role", "admin")

    case Accounts.create_user(Actor.anonymous(), attrs) do
      {:ok, _user} ->
        {:noreply, assign(socket, :trigger_submit, true)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "user"))}
    end
  end

  defp assign_form(socket) do
    assign(
      socket,
      :form,
      to_form(%{"email" => "", "name" => "", "password" => "", "password_confirmation" => ""},
        as: "user"
      )
    )
  end
end
