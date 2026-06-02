defmodule StillWeb.BootstrapControllerTest do
  use StillWeb.ConnCase, async: false

  import Still.AccountsFixtures

  describe "POST /api/bootstrap" do
    test "creates the first admin user and returns a session token", %{conn: conn} do
      conn =
        post(conn, "/api/bootstrap", %{
          "email" => "admin@example.com",
          "name" => "Admin",
          "password" => valid_user_password()
        })

      body = json_response(conn, 201)
      assert body["data"]["user"]["email"] == "admin@example.com"
      assert body["data"]["user"]["role"] == "admin"
      assert is_binary(body["data"]["token"])
      refute Map.has_key?(body["data"], "api_key")
    end

    test "the returned session token logs the new admin straight in", %{conn: conn} do
      conn =
        post(conn, "/api/bootstrap", %{
          "email" => "admin@example.com",
          "name" => "Admin",
          "password" => valid_user_password()
        })

      token = json_response(conn, 201)["data"]["token"]

      me =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/auth/me")
        |> json_response(200)

      assert me["data"]["user"]["email"] == "admin@example.com"
    end

    test "the token can mint an API key — the API-only/CI path without a dashboard", %{conn: conn} do
      conn =
        post(conn, "/api/bootstrap", %{
          "email" => "admin@example.com",
          "name" => "Admin",
          "password" => valid_user_password()
        })

      token = json_response(conn, 201)["data"]["token"]

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/api_keys", %{"name" => "ci-deploy", "permissions" => ["deploy", "read"]})
        |> json_response(201)

      assert String.starts_with?(body["data"]["raw_key"], "still_")
    end

    test "forces the role to admin regardless of input", %{conn: conn} do
      conn =
        post(conn, "/api/bootstrap", %{
          "email" => "admin@example.com",
          "name" => "Admin",
          "password" => valid_user_password(),
          "role" => "viewer"
        })

      body = json_response(conn, 201)
      assert body["data"]["user"]["role"] == "admin"
    end

    test "returns 409 when a user already exists", %{conn: conn} do
      _existing = user_fixture()

      conn =
        post(conn, "/api/bootstrap", %{
          "email" => "second@example.com",
          "name" => "Second",
          "password" => valid_user_password()
        })

      assert json_response(conn, 409)["error"]["message"] =~ "already complete"
    end

    test "returns 422 on invalid user attributes", %{conn: conn} do
      conn =
        post(conn, "/api/bootstrap", %{
          "email" => "not-an-email",
          "name" => "Admin",
          "password" => "short"
        })

      body = json_response(conn, 422)
      assert body["error"]["message"] == "Validation failed"
    end

    test "returns 400 when required fields are missing", %{conn: conn} do
      conn = post(conn, "/api/bootstrap", %{})
      assert json_response(conn, 400)["error"]["message"] =~ "Bad request"
    end
  end
end
