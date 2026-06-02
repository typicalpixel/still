defmodule StillWeb.Plugs.LoginRateLimit do
  @moduledoc """
  Throttles unauthenticated login attempts per client IP.

  Over the budget it halts with `429` + `Retry-After` rather than locking the
  account out — a lockout would let an attacker DoS a legit user out of their
  own account. Keys on `conn.remote_ip`, which `StillWeb.Plugs.ClientIp` has
  already resolved to the real client behind Caddy.

  Configured via `:still, :login_rate_limit` (`:enabled`, `:max_attempts`,
  `:window_ms`); disabled by default in the test/dev envs so unrelated login
  tests don't trip it.
  """

  @behaviour Plug

  import Plug.Conn

  alias Still.RateLimiter

  @impl true
  def init(opts) when is_list(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    config = Application.get_env(:still, :login_rate_limit, [])

    if Keyword.get(config, :enabled, false) do
      throttle(conn, config)
    else
      conn
    end
  end

  defp throttle(conn, config) do
    max = Keyword.get(config, :max_attempts, 10)
    window_ms = Keyword.get(config, :window_ms, 60_000)
    key = "login:" <> ip_string(conn.remote_ip)

    case RateLimiter.hit(key, max, window_ms) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_status(:too_many_requests)
        |> Phoenix.Controller.json(%{
          error: %{message: "Too many login attempts. Try again later."}
        })
        |> halt()
    end
  end

  # conn.remote_ip is always an address tuple (Plug guarantees it, and ClientIp
  # only ever sets a parsed one), so a single clause covers every request.
  defp ip_string(ip), do: ip |> :inet.ntoa() |> to_string()
end
