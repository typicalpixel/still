defmodule StillWeb.AuthControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.Audit.Actor

  import Still.AccountsFixtures

  describe "POST /api/auth/login" do
    test "returns a session token and user on valid credentials", %{conn: conn} do
      user = user_fixture(email: "alice@example.com")

      conn =
        post(conn, "/api/auth/login", %{
          "email" => "alice@example.com",
          "password" => valid_user_password()
        })

      body = json_response(conn, 200)
      assert is_binary(body["data"]["token"])
      assert body["data"]["user"]["email"] == "alice@example.com"
      assert body["data"]["user"]["id"] == user.id
      refute Map.has_key?(body["data"]["user"], "hashed_password")
    end

    test "returns 401 on invalid password", %{conn: conn} do
      user_fixture(email: "alice@example.com")

      conn =
        post(conn, "/api/auth/login", %{
          "email" => "alice@example.com",
          "password" => "wrong password!"
        })

      assert json_response(conn, 401)["error"]["message"] =~ "Invalid"
    end

    test "returns 401 on unknown email", %{conn: conn} do
      conn =
        post(conn, "/api/auth/login", %{
          "email" => "ghost@example.com",
          "password" => "anything"
        })

      assert json_response(conn, 401)["error"]["message"] =~ "Invalid"
    end

    test "returns 400 when email or password are missing", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{})
      assert json_response(conn, 400)["error"]["message"] =~ "Bad request"
    end

    test "throttles repeated logins from the same IP with 429 + Retry-After", %{conn: conn} do
      original = Application.get_env(:still, :login_rate_limit)

      Application.put_env(:still, :login_rate_limit,
        enabled: true,
        max_attempts: 2,
        window_ms: 60_000
      )

      Still.RateLimiter.reset()

      on_exit(fn ->
        Application.put_env(:still, :login_rate_limit, original)
        Still.RateLimiter.reset()
      end)

      attempt = fn ->
        post(conn, "/api/auth/login", %{"email" => "ghost@example.com", "password" => "nope"})
      end

      # Two bad attempts are allowed (each 401s on credentials)...
      assert attempt.().status == 401
      assert attempt.().status == 401

      # ...the third trips the per-IP budget.
      blocked = attempt.()
      assert blocked.status == 429
      assert get_resp_header(blocked, "retry-after") != []
      assert json_response(blocked, 429)["error"]["message"] =~ "Too many login attempts"
    end
  end

  describe "POST /api/auth/logout" do
    test "invalidates the session token and returns 204", %{conn: conn} do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      encoded = Base.url_encode64(token, padding: false)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{encoded}")
        |> post("/api/auth/logout")

      assert conn.status == 204

      # Token is now invalid
      refute Accounts.get_user_by_session_token(token)
    end

    test "returns 204 even when called with an API key (idempotent)", %{conn: conn} do
      user = user_fixture()

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["read"]})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key.raw_key}")
        |> post("/api/auth/logout")

      assert conn.status == 204
    end
  end

  describe "GET /api/auth/me" do
    test "returns the current user", %{conn: conn} do
      user = user_fixture(email: "alice@example.com", name: "Alice", role: :admin)

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["read"]})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key.raw_key}")
        |> get("/api/auth/me")

      body = json_response(conn, 200)
      assert body["data"]["user"]["email"] == "alice@example.com"
      assert body["data"]["user"]["name"] == "Alice"
      assert body["data"]["user"]["role"] == "admin"
    end

    test "returns 401 without a token", %{conn: conn} do
      conn = get(conn, "/api/auth/me")
      assert json_response(conn, 401)["error"]["message"] =~ "Missing or invalid"
    end
  end

  describe "PATCH /api/auth/me" do
    setup %{conn: conn} do
      user = user_fixture(%{email: "self@example.com", name: "Original"})

      {:ok, key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "self", permissions: ["read"]})

      %{conn: put_req_header(conn, "authorization", "Bearer #{key.raw_key}"), user: user}
    end

    test "updates the caller's own name", %{conn: conn} do
      body = conn |> patch("/api/auth/me", %{name: "Renamed"}) |> json_response(200)
      assert body["data"]["name"] == "Renamed"
      assert body["data"]["email"] == "self@example.com"
    end

    test "ignores attempts to change role or email via the profile endpoint", %{conn: conn} do
      body =
        conn
        |> patch("/api/auth/me", %{name: "Ok", role: "admin", email: "hacker@example.com"})
        |> json_response(200)

      assert body["data"]["name"] == "Ok"
      assert body["data"]["email"] == "self@example.com"
      assert body["data"]["role"] == "viewer"
    end
  end

  describe "POST /api/auth/me/password" do
    setup %{conn: conn} do
      user = user_fixture(%{email: "rotator@example.com"})

      {:ok, key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "k", permissions: ["read"]})

      %{conn: put_req_header(conn, "authorization", "Bearer #{key.raw_key}"), user: user}
    end

    test "rotates the password when the current one matches", %{conn: conn, user: user} do
      conn =
        post(conn, "/api/auth/me/password", %{
          current_password: valid_user_password(),
          password: "brand new pass 123"
        })

      assert conn.status == 204

      assert is_nil(Accounts.get_user_by_email_and_password(user.email, valid_user_password()))
      assert %{} = Accounts.get_user_by_email_and_password(user.email, "brand new pass 123")
    end

    test "returns 401 when the current password is wrong", %{conn: conn} do
      conn =
        post(conn, "/api/auth/me/password", %{
          current_password: "definitely wrong",
          password: "brand new pass 123"
        })

      assert conn.status == 401
    end

    test "returns 400 when fields are missing", %{conn: conn} do
      conn = post(conn, "/api/auth/me/password", %{})
      assert conn.status == 400
    end

    test "disconnects the user's other live sessions", %{conn: conn, user: user} do
      session_token = Accounts.generate_user_session_token(user)
      topic = "users_sessions:#{Base.url_encode64(session_token)}"
      StillWeb.Endpoint.subscribe(topic)

      conn =
        post(conn, "/api/auth/me/password", %{
          current_password: valid_user_password(),
          password: "brand new pass 123"
        })

      assert conn.status == 204
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^topic}
      assert is_nil(Accounts.get_user_by_session_token(session_token))
    end
  end
end
