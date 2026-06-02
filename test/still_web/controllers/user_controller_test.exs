defmodule StillWeb.UserControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.Audit.Actor

  import Still.AccountsFixtures

  setup %{conn: conn} do
    admin = user_fixture(%{role: :admin, email: "admin@example.com"})

    {:ok, key} =
      Accounts.create_api_key(Actor.system(), admin, %{name: "ops", permissions: ["admin"]})

    %{conn: put_req_header(conn, "authorization", "Bearer #{key.raw_key}"), admin: admin}
  end

  describe "GET /api/users" do
    test "lists all users", %{conn: conn, admin: admin} do
      _other = user_fixture(%{email: "other@example.com"})
      body = conn |> get("/api/users") |> json_response(200)

      emails = Enum.map(body["data"], & &1["email"])
      assert "admin@example.com" in emails
      assert "other@example.com" in emails

      first = hd(body["data"])
      refute Map.has_key?(first, "hashed_password")
      refute Map.has_key?(first, "password")
      assert first["id"] == admin.id || first["email"] == "other@example.com"
    end

    test "requires admin permission" do
      reader = user_fixture(%{role: :viewer})

      {:ok, key} =
        Accounts.create_api_key(Actor.system(), reader, %{name: "r", permissions: ["read"]})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key.raw_key}")
        |> get("/api/users")

      assert conn.status == 403
    end
  end

  describe "GET /api/users/:id" do
    test "returns the user", %{conn: conn} do
      user = user_fixture(%{email: "fetched@example.com"})
      body = conn |> get("/api/users/#{user.id}") |> json_response(200)
      assert body["data"]["email"] == "fetched@example.com"
    end

    test "returns 404 when not found", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/api/users/#{Ecto.UUID.generate()}") end
    end
  end

  describe "POST /api/users" do
    test "creates a new user", %{conn: conn} do
      body =
        conn
        |> post("/api/users", %{
          email: "new@example.com",
          name: "New User",
          role: "deployer",
          password: valid_user_password()
        })
        |> json_response(201)

      assert body["data"]["email"] == "new@example.com"
      assert body["data"]["role"] == "deployer"
    end

    test "returns 422 on invalid input", %{conn: conn} do
      conn = post(conn, "/api/users", %{})
      assert conn.status == 422
    end
  end

  describe "PATCH /api/users/:id" do
    test "updates name and role", %{conn: conn} do
      user = user_fixture(%{role: :viewer, name: "Old Name"})

      body =
        conn
        |> patch("/api/users/#{user.id}", %{
          email: user.email,
          name: "New Name",
          role: "deployer"
        })
        |> json_response(200)

      assert body["data"]["name"] == "New Name"
      assert body["data"]["role"] == "deployer"
    end

    test "refuses to demote the last admin", %{conn: conn, admin: admin} do
      conn =
        patch(conn, "/api/users/#{admin.id}", %{
          email: admin.email,
          name: admin.name,
          role: "viewer"
        })

      assert conn.status == 409
      assert json_response(conn, 409)["error"]["message"] =~ "last admin"
    end

    test "allows demoting an admin when another admin exists", %{conn: conn, admin: admin} do
      _admin2 = user_fixture(%{role: :admin, email: "admin2@example.com"})

      body =
        conn
        |> patch("/api/users/#{admin.id}", %{
          email: admin.email,
          name: admin.name,
          role: "deployer"
        })
        |> json_response(200)

      assert body["data"]["role"] == "deployer"
    end
  end

  describe "POST /api/users/:id/password" do
    test "rotates the password without requiring the current one", %{conn: conn} do
      user = user_fixture()

      conn = post(conn, "/api/users/#{user.id}/password", %{password: "fresh password 123"})
      assert conn.status == 204

      # Old password no longer works.
      assert is_nil(Accounts.get_user_by_email_and_password(user.email, valid_user_password()))
      # New password does.
      assert %{} = Accounts.get_user_by_email_and_password(user.email, "fresh password 123")
    end

    test "returns 422 when the new password is too short", %{conn: conn} do
      user = user_fixture()
      conn = post(conn, "/api/users/#{user.id}/password", %{password: "short"})
      assert conn.status == 422
    end

    test "disconnects the target user's live sessions", %{conn: conn} do
      user = user_fixture()
      session_token = Accounts.generate_user_session_token(user)
      topic = "users_sessions:#{Base.url_encode64(session_token)}"
      StillWeb.Endpoint.subscribe(topic)

      conn = post(conn, "/api/users/#{user.id}/password", %{password: "fresh password 123"})

      assert conn.status == 204
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
      assert is_nil(Accounts.get_user_by_session_token(session_token))
    end
  end

  describe "DELETE /api/users/:id" do
    test "deletes a user", %{conn: conn} do
      user = user_fixture(%{email: "doomed@example.com"})

      conn = delete(conn, "/api/users/#{user.id}")
      assert conn.status == 204

      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(user.id) end
    end

    test "refuses to delete self", %{conn: conn, admin: admin} do
      conn = delete(conn, "/api/users/#{admin.id}")
      assert conn.status == 409
      assert json_response(conn, 409)["error"]["message"] =~ "your own account"
    end

    # Note: the "last admin" guard for DELETE is unreachable from the
    # controller because the only person who could try to delete the last
    # admin IS the last admin, and `:cannot_delete_self` fires first.
    # The Accounts unit tests cover the underlying `:last_admin` path
    # directly via `Actor.system()`.
  end
end
