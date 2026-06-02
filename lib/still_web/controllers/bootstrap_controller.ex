defmodule StillWeb.BootstrapController do
  @moduledoc """
  One-shot first-user creation. Returns 409 once any user exists.
  """

  use StillWeb, :controller

  use OpenApiSpex.ControllerSpecs

  action_fallback StillWeb.FallbackController

  alias Still.Accounts
  alias Still.Audit.Actor
  alias StillWeb.Schemas

  tags(["Bootstrap"])

  operation(:create,
    summary: "Create the first admin user",
    description: ~S"""
    One-shot endpoint: returns 409 once any user exists. The response
    includes a session token — bearer it to log the new admin straight in,
    same as `POST /api/auth/login`. Create API keys explicitly afterwards
    via `POST /api/api_keys` when you need CI/CLI access.
    """,
    security: [],
    request_body: {"First-admin credentials", "application/json", Schemas.BootstrapRequest},
    responses: [
      created:
        {"Admin user created and signed in", "application/json", Schemas.BootstrapResponse},
      conflict: {"Bootstrap already complete", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation failed", "application/json", Schemas.Error},
      bad_request: {"Missing required fields", "application/json", Schemas.Error}
    ]
  )

  @doc "Creates the first admin user and returns a session token."
  def create(%Plug.Conn{} = conn, %{"email" => _, "name" => _, "password" => _} = params) do
    if Accounts.has_users?() do
      {:error, :bootstrap_already_complete}
    else
      create_admin(conn, params)
    end
  end

  def create(%Plug.Conn{} = _conn, _params) do
    {:error, :bad_request}
  end

  defp create_admin(conn, params) do
    attrs = Map.put(params, "role", "admin")
    actor = Actor.from_conn(conn)

    case Accounts.create_user(actor, attrs) do
      {:ok, user} ->
        token =
          user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)

        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            user: %{id: user.id, email: user.email, name: user.name, role: user.role},
            token: token
          }
        })

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
