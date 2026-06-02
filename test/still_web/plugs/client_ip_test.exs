defmodule StillWeb.Plugs.ClientIpTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias StillWeb.Plugs.ClientIp

  defp call(headers) do
    conn = conn(:get, "/")

    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> ClientIp.call(ClientIp.init([]))
  end

  test "sets remote_ip from a single X-Forwarded-For entry" do
    assert call([{"x-forwarded-for", "1.2.3.4"}]).remote_ip == {1, 2, 3, 4}
  end

  test "uses the last entry (the one the trusted proxy appended), ignoring a forged leading one" do
    assert call([{"x-forwarded-for", "9.9.9.9, 5.6.7.8"}]).remote_ip == {5, 6, 7, 8}
  end

  test "parses IPv6" do
    assert call([{"x-forwarded-for", "::1"}]).remote_ip == {0, 0, 0, 0, 0, 0, 0, 1}
  end

  test "leaves remote_ip untouched when the header is absent" do
    conn = conn(:get, "/")
    assert ClientIp.call(conn, ClientIp.init([])).remote_ip == conn.remote_ip
  end

  test "leaves remote_ip untouched when the header is unparseable" do
    before = conn(:get, "/").remote_ip
    assert call([{"x-forwarded-for", "not-an-ip"}]).remote_ip == before
  end
end
