defmodule StillWeb.UserLive.Login do
  use StillWeb, :live_view

  alias Still.Accounts

  @doc "Renders the login form."
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="relative isolate flex min-h-[calc(100vh-3rem)] items-center justify-center">
        <div
          class="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-2/3 bg-[radial-gradient(60%_80%_at_50%_120%,color-mix(in_srgb,var(--color-tide)_22%,transparent),transparent_60%)]"
          aria-hidden="true"
        >
        </div>

        <div class="w-full max-w-sm">
          <div class="mb-6 flex flex-col items-center text-center">
            <.sail class="h-9 w-auto text-paper-900 dark:text-ink-50" />
            <h1 class="mt-4 font-display text-[26px] font-medium tracking-[-0.02em] text-paper-900 dark:text-ink-50">
              Log in to Still
            </h1>
            <p class="mt-1 text-[13px] text-paper-500 dark:text-ink-300">
              Enter your email and password.
            </p>
          </div>

          <div class="card-surface rounded-2xl p-6">
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
        </div>
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
