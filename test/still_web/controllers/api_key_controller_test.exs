defmodule StillWeb.ApiKeyControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.Audit.Actor

  import Still.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, api_key} =
      Accounts.create_api_key(Actor.system(), user, %{name: "auth", permissions: ["admin"]})

    conn = put_req_header(conn, "authorization", "Bearer #{api_key.raw_key}")
    %{conn: conn, user: user, auth_key: api_key}
  end

  describe "GET /api/api_keys" do
    test "lists the current user's keys", %{conn: conn, auth_key: auth_key} do
      body = conn |> get("/api/api_keys") |> json_response(200)

      ids = Enum.map(body["data"], & &1["id"])
      assert auth_key.id in ids

      # No raw_key or hashed_key exposed
      first = hd(body["data"])
      refute Map.has_key?(first, "raw_key")
      refute Map.has_key?(first, "hashed_key")
    end

    test "does not return other users' keys", %{conn: conn} do
      other_user = user_fixture()

      {:ok, _} =
        Accounts.create_api_key(Actor.system(), other_user, %{
          name: "other",
          permissions: ["read"]
        })

      body = conn |> get("/api/api_keys") |> json_response(200)
      names = Enum.map(body["data"], & &1["name"])
      refute "other" in names
    end
  end

  describe "POST /api/api_keys" do
    test "creates a key and returns the raw key once", %{conn: conn} do
      body =
        conn
        |> post("/api/api_keys", %{"name" => "ci-deploy", "permissions" => ["deploy", "read"]})
        |> json_response(201)

      assert body["data"]["name"] == "ci-deploy"
      assert body["data"]["permissions"] == ["deploy", "read"]
      assert String.starts_with?(body["data"]["raw_key"], "still_")
    end

    test "returns 422 on invalid attributes", %{conn: conn} do
      body = conn |> post("/api/api_keys", %{}) |> json_response(422)
      assert body["error"]["message"] == "Validation failed"
    end
  end

  describe "DELETE /api/api_keys/:id" do
    test "revokes the key", %{conn: conn, user: user} do
      {:ok, key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "doomed", permissions: ["read"]})

      conn = delete(conn, "/api/api_keys/#{key.id}")
      assert conn.status == 204
    end

    test "returns 404 when the key belongs to another user", %{conn: conn} do
      other_user = user_fixture()

      {:ok, other_key} =
        Accounts.create_api_key(Actor.system(), other_user, %{name: "x", permissions: ["read"]})

      body = conn |> delete("/api/api_keys/#{other_key.id}") |> json_response(404)
      assert body["error"]["message"] == "Not found"
    end
  end
end
