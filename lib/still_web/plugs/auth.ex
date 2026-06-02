defmodule StillWeb.Plugs.Auth do
  @moduledoc """
  Authenticates requests via the `Authorization: Bearer <token>` header.

  Tries two token types in order:

    1. **API key** — raw string starting with `still_`, hashed and looked up
    2. **Session token** — base64url-encoded bytes, decoded and looked up

  On success, assigns `:current_user` and `:current_scope` on the conn —
  the scope wraps the user *and* the API key (when present) so the
  downstream `StillWeb.Plugs.Authorize` plug can enforce permissions
  without re-querying. Successful API-key authentications also stamp
  `last_used_at` so operators can see which keys are active. On failure,
  halts with a 401 JSON response.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Still.Accounts
  alias Still.Accounts.Scope
  alias Still.Audit
  alias Still.Audit.Actor

  @doc "Plug init — no options."
  def init(opts) when is_list(opts), do: opts

  @doc "Plug call — authenticate or halt."
  def call(%Plug.Conn{} = conn, _opts) do
    case get_token(conn) do
      nil ->
        record_auth_failure(conn, :missing)
        unauthorized(conn)

      token ->
        case Accounts.authenticate_bearer(token) do
          {:ok, user, api_key} ->
            touch_api_key(api_key)
            assign_scope(conn, user, api_key)

          :error ->
            record_auth_failure(conn, :invalid)
            unauthorized(conn)
        end
    end
  end

  # Records the failed bearer-auth attempt so SOC 2 reviewers can answer
  # "what IP / UA tried to authenticate, and when". The token itself is
  # never written — only its presence/absence and the request metadata.
  defp record_auth_failure(conn, reason) when reason in [:missing, :invalid] do
    {:ok, _} =
      Audit.record(Actor.from_conn(conn),
        type: :api_key_auth_failed,
        payload: %{
          reason: reason,
          method: conn.method,
          path: conn.request_path
        }
      )

    :ok
  end

  defp get_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp assign_scope(conn, user, api_key) do
    scope =
      user
      |> Scope.for_user()
      |> Scope.put_api_key(api_key)

    conn
    |> assign(:current_user, user)
    |> assign(:current_scope, scope)
  end

  defp touch_api_key(nil), do: :ok
  defp touch_api_key(api_key), do: Accounts.touch_api_key_used(api_key)

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{message: "Missing or invalid authentication token"}})
    |> halt()
  end
end
