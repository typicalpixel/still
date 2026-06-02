defmodule StillWeb.UserController do
  @moduledoc """
  Admin CRUD for user accounts. The bootstrap endpoint creates the
  first admin; everything after that flows through here.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  plug StillWeb.Plugs.Authorize, :admin

  alias Still.Accounts
  alias Still.Audit.Actor
  alias StillWeb.Schemas
  alias StillWeb.Schemas.Envelope
  alias StillWeb.UserAuth
  alias StillWeb.UserJSON

  tags(["Users"])

  @id_param [
    id: [in: :path, schema: %OpenApiSpex.Schema{type: :string, format: :uuid}, required: true]
  ]

  operation(:index,
    summary: "List all users (admin)",
    responses: [
      ok: {"Users", "application/json", Envelope.list(Schemas.User)},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Lists all users."
  def index(%Plug.Conn{} = conn, _params) do
    json(conn, UserJSON.render(Accounts.list_users()))
  end

  operation(:show,
    summary: "Show a user by id (admin)",
    parameters: @id_param,
    responses: [
      ok: {"User", "application/json", Envelope.single(Schemas.User)},
      not_found: {"Unknown id", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Shows a single user."
  def show(%Plug.Conn{} = conn, %{"id" => id}) do
    user = Accounts.get_user!(id)
    json(conn, UserJSON.render_one(user))
  end

  operation(:create,
    summary: "Create a user (admin)",
    description: "Bootstrap creates the first admin; everything after that flows through here.",
    request_body: {"User attributes", "application/json", Schemas.CreateUserRequest},
    responses: [
      created: {"User", "application/json", Envelope.single(Schemas.User)},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Creates a user. Same shape as bootstrap but admin-gated."
  def create(%Plug.Conn{} = conn, params) when is_map(params) do
    with {:ok, user} <- Accounts.create_user(Actor.from_conn(conn), params) do
      conn |> put_status(:created) |> json(UserJSON.render_one(user))
    end
  end

  operation(:update,
    summary: "Update a user's email, name, or role (admin)",
    parameters: @id_param,
    request_body: {"User patch", "application/json", Schemas.UpdateUserRequest},
    responses: [
      ok: {"User", "application/json", Envelope.single(Schemas.User)},
      conflict:
        {"Refusing to demote the last admin or other invariant violation", "application/json",
         Schemas.Error},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Updates a user's email, name, or role."
  def update(%Plug.Conn{} = conn, %{"id" => id} = params) do
    user = Accounts.get_user!(id)

    with {:ok, updated} <- Accounts.update_user(Actor.from_conn(conn), user, params) do
      json(conn, UserJSON.render_one(updated))
    end
  end

  operation(:update_password,
    summary: "Reset a user's password (admin)",
    description:
      "Admin authority — no current-password check. For self-service, use `POST /api/auth/me/password`.",
    parameters: @id_param,
    request_body: {"New password", "application/json", Schemas.AdminPasswordResetRequest},
    responses: [
      no_content: "Password reset",
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Resets a user's password. No current-password check — admin authority."
  def update_password(%Plug.Conn{} = conn, %{"id" => id} = params) do
    user = Accounts.get_user!(id)

    with {:ok, {_updated, expired_tokens}} <-
           Accounts.update_user_password(Actor.from_conn(conn), user, params) do
      UserAuth.disconnect_sessions(expired_tokens)
      send_resp(conn, :no_content, "")
    end
  end

  operation(:delete,
    summary: "Delete a user (admin)",
    description: ~S"""
    Refuses (409) if the deletion would leave zero admins, or if the
    actor is trying to delete their own account.
    """,
    parameters: @id_param,
    responses: [
      no_content: "Deleted",
      conflict: {"Refusing to delete self or the last admin", "application/json", Schemas.Error},
      forbidden: {"Admin permission required", "application/json", Schemas.Error}
    ]
  )

  @doc "Deletes a user. Refuses if it would leave zero admins or delete self."
  def delete(%Plug.Conn{} = conn, %{"id" => id}) do
    user = Accounts.get_user!(id)

    with {:ok, _deleted} <- Accounts.delete_user(Actor.from_conn(conn), user) do
      send_resp(conn, :no_content, "")
    end
  end
end
