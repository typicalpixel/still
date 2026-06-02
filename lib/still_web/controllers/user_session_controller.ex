defmodule StillWeb.UserSessionController do
  @moduledoc """
  Browser email/password login and logout. Sets the session cookie the
  LiveView dashboard authenticates with. Records the same audit events as the
  JSON `AuthController` so dashboard and API logins share one audit trail.
  """

  use StillWeb, :controller

  alias Still.Accounts
  alias Still.Accounts.Scope
  alias Still.Audit
  alias Still.Audit.Actor
  alias StillWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email, "password" => password} = user_params})
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        {:ok, _} =
          Audit.record(Actor.from_conn(conn),
            type: :login_failed,
            payload: %{attempted_email: email}
          )

        # Don't disclose whether the email is registered.
        conn
        |> put_flash(:error, "Invalid email or password")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      user ->
        actor = Actor.with_conn(Actor.from_scope(Scope.for_user(user)), conn)

        {:ok, _} =
          Audit.record(actor,
            type: :login_succeeded,
            subject_type: :user,
            subject_id: user.id,
            payload: %{user_id: user.id, email: user.email}
          )

        conn
        |> put_flash(:info, "Welcome back!")
        |> UserAuth.log_in_user(user, user_params)
    end
  end

  def delete(conn, _params) do
    user = conn.assigns[:current_user]

    if user do
      {:ok, _} =
        Audit.record(Actor.from_conn(conn),
          type: :logout,
          subject_type: :user,
          subject_id: user.id,
          payload: %{user_id: user.id, email: user.email}
        )
    end

    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
