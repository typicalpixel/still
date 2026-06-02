defmodule StillWeb.HookControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.Audit.Actor

  import Still.AccountsFixtures
  import Still.ApplicationsFixtures

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, api_key} =
      Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["admin"]})

    conn = put_req_header(conn, "authorization", "Bearer #{api_key.raw_key}")
    %{conn: conn}
  end

  describe "GET /api/applications/:name/hooks" do
    test "lists hooks for the application", %{conn: conn} do
      app = application_fixture(%{name: "my-api"})
      hook_fixture(app, %{event: :pre_deploy})

      body = conn |> get("/api/applications/my-api/hooks") |> json_response(200)
      assert length(body["data"]) == 1
      assert hd(body["data"])["event"] == "pre_deploy"
    end
  end

  describe "POST /api/applications/:name/hooks" do
    test "creates a hook", %{conn: conn} do
      application_fixture(%{name: "my-api"})

      body =
        conn
        |> post("/api/applications/my-api/hooks", %{
          "event" => "pre_deploy",
          "script" => "#!/bin/bash\necho deploying",
          "timeout_ms" => 30_000
        })
        |> json_response(201)

      assert body["data"]["event"] == "pre_deploy"
      assert body["data"]["script"] == "#!/bin/bash\necho deploying"
      assert body["data"]["timeout_ms"] == 30_000
    end

    test "returns 422 on invalid attributes", %{conn: conn} do
      application_fixture(%{name: "my-api"})

      body =
        conn
        |> post("/api/applications/my-api/hooks", %{})
        |> json_response(422)

      assert body["error"]["message"] == "Validation failed"
    end
  end

  describe "PATCH /api/applications/:name/hooks/:id" do
    test "updates the hook's script", %{conn: conn} do
      app = application_fixture(%{name: "my-api"})
      hook = hook_fixture(app, %{script: "old"})

      body =
        conn
        |> patch("/api/applications/my-api/hooks/#{hook.id}", %{"script" => "new"})
        |> json_response(200)

      assert body["data"]["script"] == "new"
    end

    test "returns 422 on invalid update", %{conn: conn} do
      app = application_fixture(%{name: "my-api"})
      hook = hook_fixture(app)

      body =
        conn
        |> patch("/api/applications/my-api/hooks/#{hook.id}", %{"script" => ""})
        |> json_response(422)

      assert body["error"]["message"] == "Validation failed"
    end
  end

  describe "DELETE /api/applications/:name/hooks/:id" do
    test "deletes the hook", %{conn: conn} do
      app = application_fixture(%{name: "my-api"})
      hook = hook_fixture(app)

      conn = delete(conn, "/api/applications/my-api/hooks/#{hook.id}")
      assert conn.status == 204
    end
  end
end
