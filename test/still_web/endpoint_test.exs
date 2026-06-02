defmodule StillWeb.EndpointTest do
  use StillWeb.ConnCase, async: false

  # The endpoint runs Plug.RewriteOn before the router, so a request Caddy
  # forwarded as HTTPS is seen as :https here — which is what makes Plug mark
  # cookies Secure. /api/openapi is unauthenticated and DB-free, and the scheme
  # is rewritten before routing, so the assertion holds regardless of the body.
  describe "X-Forwarded-Proto handling" do
    test "treats the request as HTTPS when Caddy forwards proto https", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-forwarded-proto", "https")
        |> get(~p"/api/openapi")

      assert conn.scheme == :https
    end

    test "leaves the request as HTTP when no forwarded proto is present", %{conn: conn} do
      assert get(conn, ~p"/api/openapi").scheme == :http
    end
  end
end
