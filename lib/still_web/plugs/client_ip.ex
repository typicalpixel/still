defmodule StillWeb.Plugs.ClientIp do
  @moduledoc """
  Rewrites `conn.remote_ip` from the last `X-Forwarded-For` entry.

  Still's endpoint binds loopback and is fronted by Caddy, so the raw socket
  peer is always `127.0.0.1`. Caddy appends the real client address as the last
  `X-Forwarded-For` entry — appending (rather than trusting a client-supplied
  value) means a forged leading entry is ignored, so the last entry is the
  address Caddy actually saw. Audit rows and access logs then record the real
  client instead of loopback.

  No-op when the header is absent (direct/dev access) or unparseable.
  """

  @behaviour Plug

  import Plug.Conn, only: [get_req_header: 2]

  @impl true
  def init(opts) when is_list(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case client_ip(conn) do
      nil -> conn
      address -> %{conn | remote_ip: address}
    end
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [] ->
        nil

      values ->
        values
        |> Enum.join(",")
        |> String.split(",")
        |> List.last()
        |> String.trim()
        |> parse_ip()
    end
  end

  defp parse_ip(string) do
    case :inet.parse_address(String.to_charlist(string)) do
      {:ok, address} -> address
      {:error, _} -> nil
    end
  end
end
