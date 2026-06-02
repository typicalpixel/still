defmodule StillWeb.ApplicationControllerTest do
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

  describe "GET /api/applications" do
    test "lists all applications", %{conn: conn} do
      application_fixture(%{name: "alpha"})
      application_fixture(%{name: "bravo"})

      body = conn |> get("/api/applications") |> json_response(200)
      names = Enum.map(body["data"], & &1["name"])
      assert "alpha" in names
      assert "bravo" in names
    end
  end

  describe "POST /api/applications" do
    test "creates an application", %{conn: conn} do
      body =
        conn
        |> post("/api/applications", %{
          "name" => "my-api",
          "type" => "elixir_release",
          "domain" => "api.example.com",
          "exec_command" => "bin/my_api start",
          "min_healthy" => 1,
          "health_check" => %{
            "path" => "/health",
            "interval_ms" => 5000,
            "deadline_ms" => 3000
          },
          "artifact_source" => %{"type" => "unauthenticated_url"}
        })
        |> json_response(201)

      assert body["data"]["name"] == "my-api"
      assert body["data"]["type"] == "elixir_release"
      assert body["data"]["health_check"]["path"] == "/health"
      assert body["data"]["artifact_source"]["type"] == "unauthenticated_url"
    end

    test "returns 422 on invalid attributes", %{conn: conn} do
      body = conn |> post("/api/applications", %{}) |> json_response(422)
      assert body["error"]["message"] == "Validation failed"
    end
  end

  describe "GET /api/applications/:name" do
    test "returns the application", %{conn: conn} do
      app = application_fixture(%{name: "target"})

      body = conn |> get("/api/applications/target") |> json_response(200)
      assert body["data"]["name"] == "target"
      assert body["data"]["id"] == app.id
    end
  end

  describe "PATCH /api/applications/:name" do
    test "updates mutable fields", %{conn: conn} do
      application_fixture(%{name: "mutable"})

      body =
        conn
        |> patch("/api/applications/mutable", %{"domain" => "new.example.com"})
        |> json_response(200)

      assert body["data"]["domain"] == "new.example.com"
    end

    test "returns 422 on invalid update", %{conn: conn} do
      application_fixture(%{name: "bad-update"})

      body =
        conn
        |> patch("/api/applications/bad-update", %{"min_healthy" => 0})
        |> json_response(422)

      assert body["error"]["message"] == "Validation failed"
    end
  end

  describe "GET /api/applications/:name — static_site" do
    test "renders nil health_check for static sites", %{conn: conn} do
      application_fixture(%{
        name: "my-site",
        type: :static_site,
        exec_command: nil,
        health_check: nil
      })

      body = conn |> get("/api/applications/my-site") |> json_response(200)
      assert body["data"]["health_check"] == nil
      assert body["data"]["type"] == "static_site"
    end
  end

  describe "DELETE /api/applications/:name" do
    test "deletes an application with no assignments", %{conn: conn} do
      application_fixture(%{name: "doomed"})

      conn = delete(conn, "/api/applications/doomed")
      assert conn.status == 204
    end

    test "returns 409 when the application has server assignments", %{conn: conn} do
      app = application_fixture(%{name: "busy"})
      server = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      body = conn |> delete("/api/applications/busy") |> json_response(409)
      assert body["error"]["message"] =~ "servers assigned"
    end
  end
end
