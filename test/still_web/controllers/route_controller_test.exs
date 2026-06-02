defmodule StillWeb.RouteControllerTest do
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

  describe "GET /api/routes" do
    test "returns an empty data list when no applications exist", %{conn: conn} do
      body = conn |> get("/api/routes") |> json_response(200)
      assert body["data"] == []
    end

    test "omits applications without any server assignments", %{conn: conn} do
      application_fixture(%{name: "unassigned"})
      body = conn |> get("/api/routes") |> json_response(200)
      assert body["data"] == []
    end

    test "returns one entry per assigned application with upstream list", %{conn: conn} do
      app = application_fixture(%{name: "api", domain: "api.example.com"})
      server_a = server_fixture(%{name: "agent-a", host: "10.0.0.3"})
      server_b = server_fixture(%{name: "agent-b", host: "10.0.0.4"})

      {:ok, _} = Applications.assign_server(Actor.system(), app, server_a)
      {:ok, _} = Applications.assign_server(Actor.system(), app, server_b)

      body = conn |> get("/api/routes") |> json_response(200)
      assert [entry] = body["data"]

      assert entry["name"] == "api"
      assert entry["domain"] == "api.example.com"
      assert entry["type"] == "elixir_release"
      assert entry["path_prefix"] == nil

      hosts = Enum.map(entry["upstreams"], & &1["host"]) |> Enum.sort()
      assert hosts == ["10.0.0.3", "10.0.0.4"]

      for upstream <- entry["upstreams"] do
        assert upstream["port"] == 8080
        assert upstream["dial"] == "#{upstream["host"]}:8080"
        assert is_binary(upstream["server_id"])
        assert upstream["server_name"] in ["agent-a", "agent-b"]
      end
    end

    test "returns entries for multiple applications sorted by name", %{conn: conn} do
      app_a = application_fixture(%{name: "alpha", domain: "alpha.example.com"})
      app_b = application_fixture(%{name: "bravo", domain: "bravo.example.com"})
      server = server_fixture(%{name: "shared", host: "10.0.0.5"})

      {:ok, _} = Applications.assign_server(Actor.system(), app_b, server)
      {:ok, _} = Applications.assign_server(Actor.system(), app_a, server)

      body = conn |> get("/api/routes") |> json_response(200)
      names = Enum.map(body["data"], & &1["name"])
      assert names == ["alpha", "bravo"]
    end

    test "includes path_prefix when the application has one", %{conn: conn} do
      app =
        application_fixture(%{
          name: "scoped",
          domain: "example.com",
          path_prefix: "/v1"
        })

      server = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      body = conn |> get("/api/routes") |> json_response(200)
      [entry] = body["data"]
      assert entry["path_prefix"] == "/v1"
    end

    test "requires authentication", %{conn: _conn} do
      conn = Phoenix.ConnTest.build_conn()
      conn |> get("/api/routes") |> json_response(401)
    end

    test "accepts read-only API key permissions", %{conn: _conn} do
      user = user_fixture()

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "read-only", permissions: ["read"]})

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{api_key.raw_key}")

      body = conn |> get("/api/routes") |> json_response(200)
      assert body["data"] == []
    end
  end
end
