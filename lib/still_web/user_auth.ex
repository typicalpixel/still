defmodule StillWeb.UserAuth do
  @moduledoc """
  Cookie-session authentication for the browser/LiveView dashboard.

  The JSON API authenticates per-request with a bearer token
  (`StillWeb.Plugs.Auth`); this module is the parallel path for humans: it
  reads the session token from a signed cookie, assigns `current_scope`, and
  reissues aging tokens. Both paths share the same `Still.Accounts` token store.
  """

  use StillWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Still.Accounts
  alias Still.Accounts.Scope
  alias Still.Accounts.User

  # Remember-me cookie valid for 14 days; matches the session validity intent.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_still_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # Reissue a session token once it is older than this, so an active user's
  # token can't ride the full validity window if stolen.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in, redirecting to the stored return path or `signed_in_path/1`.
  """
  def log_in_user(%Plug.Conn{} = conn, %User{} = user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out, clearing all session data and disconnecting live sockets.
  """
  def log_out_user(%Plug.Conn{} = conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      StillWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/users/log-in")
  end

  @doc """
  Authenticates the user from the session (or remember-me) token and assigns
  `current_scope`. Reissues the token if it is older than the configured age.
  """
  def fetch_current_scope_for_user(%Plug.Conn{} = conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {%User{} = user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> assign(:current_user, user)
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      _ ->
        conn
        |> assign(:current_scope, nil)
        |> assign(:current_user, nil)
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      end
    end
  end

  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # Creates a session token and stores it in the session and (optionally) the
  # remember-me cookie. Renewing the session on creation avoids fixation.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Don't renew the session if the same user is already logged in, to preserve
  # data in other open tabs and avoid CSRF errors.
  defp renew_session(conn, user) do
    if same_user_logged_in?(conn.assigns[:current_scope], user) do
      conn
    else
      delete_csrf_token()

      conn
      |> configure_session(renew: true)
      |> clear_session()
    end
  end

  defp same_user_logged_in?(%Scope{user: %User{id: id}}, %User{id: id}), do: true
  defp same_user_logged_in?(_scope, _user), do: false

  defp maybe_write_remember_me_cookie(conn, token, %{"remember_me" => "true"}, _),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, token, _params, true),
    do: write_remember_me_cookie(conn, token)

  defp maybe_write_remember_me_cookie(conn, _token, _params, _), do: conn

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing live sockets for the given session tokens.
  """
  def disconnect_sessions(tokens) when is_list(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      StillWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating `current_scope` in LiveViews.

    * `:mount_current_scope` — assigns `current_scope` (or `nil`).
    * `:require_authenticated` — assigns `current_scope`, redirecting to login
      when there is no authenticated user.
    * `:require_deploy` — halts with a redirect to `/` unless the current
      scope has `:deploy` permission. Mount after `:require_authenticated`.
  """
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:require_deploy, _params, _session, socket) do
    if Scope.can?(socket.assigns.current_scope, :deploy) do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Deploy permission required.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      with token when is_binary(token) <- session["user_token"],
           {%User{} = user, _inserted_at} <- Accounts.get_user_by_session_token(token) do
        Scope.for_user(user)
      else
        _ -> nil
      end
    end)
  end

  @doc "Path to redirect to after a successful login."
  def signed_in_path(_conn), do: ~p"/"

  @doc """
  Plug for routes that require an authenticated user.
  """
  def require_authenticated_user(%Plug.Conn{} = conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
