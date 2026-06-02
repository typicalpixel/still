defmodule StillWeb.UserLive.Login do
  use StillWeb, :live_view

  alias Still.Accounts

  @doc "Renders the login form."
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <.header>
          Log in to Still
          <:subtitle>Enter your email and password.</:subtitle>
        </.header>

        <.form
          :let={f}
          for={@form}
          id="login_form"
          action={~p"/users/log-in"}
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={f[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={f[:password]}
            type="password"
            label="Password"
            autocomplete="current-password"
            required
          />
          <.input field={f[:remember_me]} type="checkbox" label="Keep me logged in" />
          <.button class="btn btn-primary w-full" phx-disable-with="Logging in...">
            Log in <span aria-hidden="true">→</span>
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @doc "Mounts the login form, or redirects to setup when the instance has no users."
  def mount(_params, _session, socket) do
    if Accounts.has_users?() do
      email = Phoenix.Flash.get(socket.assigns.flash, :email)
      form = to_form(%{"email" => email}, as: "user")
      {:ok, assign(socket, form: form, trigger_submit: false)}
    else
      {:ok, redirect(socket, to: ~p"/bootstrap")}
    end
  end

  @doc """
  Flips `trigger_submit` so the form posts to `UserSessionController` with the
  typed credentials — a real form POST is what sets the session cookie.
  """
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
