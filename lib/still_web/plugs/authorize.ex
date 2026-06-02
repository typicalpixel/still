defmodule StillWeb.Plugs.Authorize do
  @moduledoc """
  Enforces that the request's current scope has the required permission.

  Applied per-action inside controllers:

      plug StillWeb.Plugs.Authorize, :read when action in [:index, :show]
      plug StillWeb.Plugs.Authorize, :admin when action in [:create, :update, :delete]

  The permission argument is one of `:read`, `:rollback`, `:deploy`, or
  `:admin` — see `Still.Accounts.Scope.can?/2` for the ordering and how it
  maps onto user roles and API key permission strings.

  Must run *after* `StillWeb.Plugs.Auth`, which installs
  `conn.assigns.current_scope`. If the plug is applied to a route that
  bypasses `Auth`, the request halts with 401 because there is no scope to
  check. When a scope is present but doesn't carry the required
  permission, the request halts with 403.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Still.Accounts.Scope
  alias Still.Audit
  alias Still.Audit.Actor

  @doc "Plug init — returns the required permission atom passed to `plug/2`."
  def init(permission) when permission in [:read, :rollback, :deploy, :admin], do: permission

  @doc "Plug call — allow, 403, or 401."
  def call(%Plug.Conn{} = conn, permission) when is_atom(permission) do
    case conn.assigns[:current_scope] do
      %Scope{} = scope ->
        if Scope.can?(scope, permission), do: conn, else: forbidden(conn, permission)

      _ ->
        unauthorized(conn)
    end
  end

  defp forbidden(conn, permission) do
    {:ok, _} =
      Audit.record(Actor.from_conn(conn),
        type: :permission_denied,
        payload: %{
          required_permission: permission,
          method: conn.method,
          path: conn.request_path
        }
      )

    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        message: "Insufficient permissions",
        detail: %{required: permission}
      }
    })
    |> halt()
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{message: "Missing or invalid authentication token"}})
    |> halt()
  end
end
