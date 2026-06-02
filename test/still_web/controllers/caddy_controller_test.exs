defmodule StillWeb.CaddyControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.Audit.Actor

  import Still.AccountsFixtures

  setup %{conn: conn} do
    start_supervised!(Still.AgentConnectionManager)

    user = user_fixture()

    {:ok, api_key} =
      Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["admin"]})

    conn = put_req_header(conn, "authorization", "Bearer #{api_key.raw_key}")
    %{conn: conn, user: user}
  end

  describe "GET /api/caddy" do
    test "returns the controller's live Caddy config", %{conn: conn} do
      config = %{"apps" => %{"http" => %{"servers" => %{"still" => %{"listen" => [":8080"]}}}}}
      Req.Test.stub(Still.Agent.CaddyManager, fn c -> Req.Test.json(c, config) end)

      conn = get(conn, "/api/caddy")
      assert json_response(conn, 200)["data"] == config
    end

    test "502 when Caddy's admin API is unreachable", %{conn: conn} do
      Req.Test.stub(Still.Agent.CaddyManager, fn c ->
        c |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      conn = get(conn, "/api/caddy")
      assert json_response(conn, 502)
    end
  end

  describe "GET /api/servers/:id/caddy" do
    test "503 when the server's agent is not connected", %{conn: conn} do
      conn = get(conn, "/api/servers/#{Ecto.UUID.generate()}/caddy")
      assert json_response(conn, 503)
    end
  end

  describe "authorization" do
    test "403 for a non-admin scope" do
      user = user_fixture()

      {:ok, key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "ro", permissions: ["read"]})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key.raw_key}")
        |> get("/api/caddy")

      assert json_response(conn, 403)
    end

    test "401 without authentication" do
      conn = get(build_conn(), "/api/caddy")
      assert json_response(conn, 401)
    end
  end
end
