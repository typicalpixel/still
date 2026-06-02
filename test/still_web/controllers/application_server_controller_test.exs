defmodule StillWeb.ApplicationServerControllerTest do
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
    %{conn: conn}
  end

  describe "GET /api/applications/:name/servers" do
    test "lists the servers assigned to the application", %{conn: conn} do
      app = application_fixture(%{name: "my-api"})
      server = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      body = conn |> get("/api/applications/my-api/servers") |> json_response(200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["server_id"] == server.id
    end

    test "returns an empty list when no servers are assigned", %{conn: conn} do
      application_fixture(%{name: "empty"})

      body = conn |> get("/api/applications/empty/servers") |> json_response(200)
      assert body["data"] == []
    end
  end

  describe "POST /api/applications/:name/servers" do
    test "assigns a server with auto-assigned ports", %{conn: conn} do
      application_fixture(%{name: "my-api"})
      server = server_fixture()

      body =
        conn
        |> post("/api/applications/my-api/servers", %{"server_id" => server.id})
        |> json_response(201)

      assert body["data"]["server_id"] == server.id
      assert body["data"]["port_blue"] == 20_000
      assert body["data"]["port_green"] == 20_001
    end

    test "assigns a server with explicit ports", %{conn: conn} do
      application_fixture(%{name: "my-api"})
      server = server_fixture()

      body =
        conn
        |> post("/api/applications/my-api/servers", %{
          "server_id" => server.id,
          "port_blue" => 25_000,
          "port_green" => 25_001
        })
        |> json_response(201)

      assert body["data"]["port_blue"] == 25_000
      assert body["data"]["port_green"] == 25_001
    end

    test "returns 409 when a chosen port is already in use on the server", %{conn: conn} do
      app1 = application_fixture(%{name: "app-one"})
      application_fixture(%{name: "app-two"})
      server = server_fixture()

      {:ok, _} =
        Applications.assign_server(Actor.system(), app1, server, %{
          port_blue: 25_000,
          port_green: 25_001
        })

      body =
        conn
        |> post("/api/applications/app-two/servers", %{
          "server_id" => server.id,
          "port_blue" => 25_001,
          "port_green" => 25_002
        })
        |> json_response(409)

      assert body["error"]["message"] == "A chosen port is already in use on this server"
    end

    test "returns an error when the server is already assigned", %{conn: conn} do
      app = application_fixture(%{name: "dup"})
      server = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      body =
        conn
        |> post("/api/applications/dup/servers", %{"server_id" => server.id})
        |> json_response(422)

      assert body["error"]["message"] == "Validation failed"
    end

    test "ignores non-integer port values and auto-assigns", %{conn: conn} do
      application_fixture(%{name: "auto"})
      server = server_fixture()

      body =
        conn
        |> post("/api/applications/auto/servers", %{
          "server_id" => server.id,
          "port_blue" => "bad",
          "port_green" => "also-bad"
        })
        |> json_response(201)

      assert body["data"]["port_blue"] == 20_000
      assert body["data"]["port_green"] == 20_001
    end
  end

  describe "DELETE /api/applications/:name/servers/:id" do
    test "removes the assignment", %{conn: conn} do
      app = application_fixture(%{name: "my-api"})
      server = server_fixture()
      {:ok, assignment} = Applications.assign_server(Actor.system(), app, server)

      conn = delete(conn, "/api/applications/my-api/servers/#{assignment.id}")
      assert conn.status == 204
    end
  end
end
