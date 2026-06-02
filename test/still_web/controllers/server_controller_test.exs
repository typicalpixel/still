defmodule StillWeb.ServerControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.Applications
  alias Still.Audit.Actor

  import Still.AccountsFixtures
  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, api_key} =
      Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["admin"]})

    conn = put_req_header(conn, "authorization", "Bearer #{api_key.raw_key}")

    %{conn: conn, user: user}
  end

  describe "GET /api/servers" do
    test "lists all servers", %{conn: conn} do
      server_fixture(%{name: "alpha"})
      server_fixture(%{name: "bravo"})

      conn = get(conn, "/api/servers")

      body = json_response(conn, 200)
      names = Enum.map(body["data"], & &1["name"])
      assert "alpha" in names
      assert "bravo" in names
    end

    test "returns an empty list when no servers exist", %{conn: conn} do
      conn = get(conn, "/api/servers")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "POST /api/servers" do
    test "creates a server with valid attributes", %{conn: conn} do
      conn =
        post(conn, "/api/servers", %{
          "name" => "new-server",
          "host" => "10.0.0.10",
          "roles" => ["application"]
        })

      body = json_response(conn, 201)
      assert body["data"]["name"] == "new-server"
      assert body["data"]["host"] == "10.0.0.10"
      assert body["data"]["status"] == "disconnected"
    end

    test "returns 422 on invalid attributes", %{conn: conn} do
      conn = post(conn, "/api/servers", %{})
      assert json_response(conn, 422)["error"]["message"] == "Validation failed"
    end
  end

  describe "GET /api/servers/:id" do
    test "returns the server", %{conn: conn} do
      server = server_fixture(%{name: "target"})

      conn = get(conn, "/api/servers/#{server.id}")

      body = json_response(conn, 200)
      assert body["data"]["name"] == "target"
      assert body["data"]["id"] == server.id
    end
  end

  describe "PATCH /api/servers/:id" do
    test "updates the server's name", %{conn: conn} do
      server = server_fixture(%{name: "old-name"})

      conn = patch(conn, "/api/servers/#{server.id}", %{"name" => "new-name"})

      body = json_response(conn, 200)
      assert body["data"]["name"] == "new-name"
    end

    test "returns 422 on invalid update", %{conn: conn} do
      server = server_fixture()

      conn = patch(conn, "/api/servers/#{server.id}", %{"name" => ""})
      assert json_response(conn, 422)["error"]["message"] == "Validation failed"
    end
  end

  describe "DELETE /api/servers/:id" do
    test "deletes a server with no assignments", %{conn: conn} do
      server = server_fixture()

      conn = delete(conn, "/api/servers/#{server.id}")
      assert conn.status == 204
    end

    test "returns 409 when the server has application assignments", %{conn: conn} do
      server = server_fixture()
      app = application_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      conn = delete(conn, "/api/servers/#{server.id}")
      assert json_response(conn, 409)["error"]["message"] =~ "applications assigned"
    end
  end
end
