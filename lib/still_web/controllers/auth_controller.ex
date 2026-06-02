defmodule StillWeb.AuthController do
  @moduledoc """
  Handles email/password login, logout, and current-user queries.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  # Throttle the unauthenticated login endpoint per client IP (brute-force
  # defense). Runs before the action; over budget it halts with 429.
  plug StillWeb.Plugs.LoginRateLimit when action in [:login]

  # login/1 is unauthenticated — the router pipes it through :api only.
  # All other actions run behind :authenticated, so the scope is always
  # present and at minimum the viewer-level `:read` permission applies.
  plug StillWeb.Plugs.Authorize,
       :read when action in [:logout, :me, :update_me, :update_my_password]

  alias Still.Accounts
  alias Still.Accounts.Scope
  alias Still.Accounts.User
  alias Still.Audit
  alias Still.Audit.Actor
  alias StillWeb.AuthJSON
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope
  alias StillWeb.UserAuth
  alias StillWeb.UserJSON

  tags(["Auth"])

  operation(:login,
    summary: "Login with email and password",
    description:
      "Issues a session token for the dashboard. Bearer this token on subsequent requests.",
    security: [],
    request_body: {"Login credentials", "application/json", Schemas.LoginRequest},
    responses: [
      ok: {"Session token issued", "application/json", Schemas.LoginResponse},
      unauthorized: {"Invalid email or password", "application/json", Schemas.Error},
      bad_request: {"Malformed request body", "application/json", Schemas.Error}
    ]
  )

  @doc "Authenticates with email + password and returns a session token."
  def login(%Plug.Conn{} = conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        {:ok, _} =
          Audit.record(Actor.from_conn(conn),
            type: :login_failed,
            payload: %{attempted_email: email}
          )

        {:error, :unauthorized}

      user ->
        token = Accounts.generate_user_session_token(user)
        encoded = Base.url_encode64(token, padding: false)
        actor = Actor.with_conn(Actor.from_scope(Scope.for_user(user)), conn)

        {:ok, _} =
          Audit.record(actor,
            type: :login_succeeded,
            subject_type: :user,
            subject_id: user.id,
            payload: %{user_id: user.id, email: user.email}
          )

        json(conn, AuthJSON.render_login(encoded, user))
    end
  end

  def login(%Plug.Conn{} = _conn, _params) do
    {:error, :bad_request}
  end

  operation(:logout,
    summary: "Invalidate the current session token",
    responses: [
      no_content: "Session token deleted",
      unauthorized: {"Missing or invalid token", "application/json", Schemas.Error}
    ]
  )

  @doc "Invalidates the current session token."
  def logout(%Plug.Conn{} = conn, _params) do
    # The :authenticated pipeline guarantees a Bearer header is present.
    ["Bearer " <> token] = get_req_header(conn, "authorization")

    case Base.url_decode64(String.trim(token), padding: false) do
      {:ok, decoded} -> Accounts.delete_user_session_token(decoded)
      :error -> :ok
    end

    user = conn.assigns.current_user

    {:ok, _} =
      Audit.record(Actor.from_conn(conn),
        type: :logout,
        subject_type: :user,
        subject_id: user.id,
        payload: %{user_id: user.id, email: user.email}
      )

    send_resp(conn, :no_content, "")
  end

  operation(:me,
    summary: "Return the currently authenticated user",
    responses: [
      ok: {"Current user", "application/json", Schemas.MeResponse},
      unauthorized: {"Missing or invalid token", "application/json", Schemas.Error}
    ]
  )

  @doc "Returns the currently authenticated user."
  def me(%Plug.Conn{} = conn, _params) do
    json(conn, AuthJSON.render_me(conn.assigns.current_user))
  end

  operation(:update_me,
    summary: "Update the caller's own profile",
    description: ~S"""
    Self-service. Only `name` is castable — email, role, and password
    have dedicated endpoints with stricter checks.
    """,
    request_body: {"Profile update", "application/json", Schemas.UpdateProfileRequest},
    responses: [
      ok: {"Updated user", "application/json", Envelope.single(Schemas.User)},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid token", "application/json", Schemas.Error}
    ]
  )

  @doc "Self-service profile update — currently just `:name`."
  def update_me(%Plug.Conn{} = conn, params) when is_map(params) do
    user = conn.assigns.current_user

    with {:ok, updated} <- Accounts.update_user_profile(Actor.from_conn(conn), user, params) do
      json(conn, UserJSON.render_one(updated))
    end
  end

  operation(:update_my_password,
    summary: "Rotate the caller's own password",
    description: ~S"""
    Requires `current_password` to match the stored hash. Returns 401
    on mismatch — defense in depth so a stolen session token on its
    own can't pivot to a permanent account takeover.
    """,
    request_body: {"Password change", "application/json", Schemas.ChangeMyPasswordRequest},
    responses: [
      no_content: "Password rotated",
      unauthorized:
        {"Current password is incorrect, or token is missing/invalid", "application/json",
         Schemas.Error},
      bad_request: {"Missing fields", "application/json", Schemas.Error},
      unprocessable_entity: {"New password failed validation", "application/json", Schemas.Error}
    ]
  )

  @doc """
  Self-service password change. Requires `current_password` to match;
  otherwise returns 401 — defense in depth so a stolen session token
  on its own can't pivot to a permanent account takeover.
  """
  def update_my_password(%Plug.Conn{} = conn, %{
        "current_password" => current,
        "password" => new_password
      })
      when is_binary(current) and is_binary(new_password) do
    user = conn.assigns.current_user

    if User.valid_password?(user, current) do
      with {:ok, {_updated, expired_tokens}} <-
             Accounts.update_user_password(Actor.from_conn(conn), user, %{password: new_password}) do
        UserAuth.disconnect_sessions(expired_tokens)
        send_resp(conn, :no_content, "")
      end
    else
      {:error, :current_password_invalid}
    end
  end

  def update_my_password(%Plug.Conn{} = _conn, _params) do
    {:error, :bad_request}
  end
end
