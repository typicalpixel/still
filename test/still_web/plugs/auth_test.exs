defmodule StillWeb.Plugs.AuthTest do
  use Still.DataCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest, only: [build_conn: 0]

  alias Still.Accounts
  alias Still.Audit.Actor
  alias StillWeb.Plugs.Auth

  import Still.AccountsFixtures

  defp put_bearer(conn, token) when is_binary(token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "call/2 — API key auth" do
    test "assigns current_user when the API key is valid" do
      user = user_fixture()

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["read"]})

      conn =
        build_conn()
        |> put_bearer(api_key.raw_key)
        |> Auth.call(Auth.init([]))

      assert conn.assigns.current_user.id == user.id
      refute conn.halted
    end

    test "attaches the api_key to the current scope so downstream plugs can authorize" do
      user = user_fixture()

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["deploy"]})

      conn =
        build_conn()
        |> put_bearer(api_key.raw_key)
        |> Auth.call(Auth.init([]))

      assert conn.assigns.current_scope.api_key.id == api_key.id
      assert conn.assigns.current_scope.api_key.permissions == ["deploy"]
      assert conn.assigns.current_scope.user.id == user.id
    end

    test "stamps last_used_at on the API key after a successful auth" do
      user = user_fixture()

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["read"]})

      assert is_nil(api_key.last_used_at)

      build_conn()
      |> put_bearer(api_key.raw_key)
      |> Auth.call(Auth.init([]))

      reloaded = Still.Repo.get!(Still.Accounts.ApiKey, api_key.id)
      assert %DateTime{} = reloaded.last_used_at
    end

    test "returns 401 when the API key is invalid" do
      conn =
        build_conn()
        |> put_bearer("still_invalid_key_here")
        |> Auth.call(Auth.init([]))

      assert conn.status == 401
      assert conn.halted

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] =~ "Missing or invalid"
    end
  end

  describe "call/2 — session token auth" do
    test "assigns current_user when the session token is valid" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      encoded = Base.url_encode64(token, padding: false)

      conn =
        build_conn()
        |> put_bearer(encoded)
        |> Auth.call(Auth.init([]))

      assert conn.assigns.current_user.id == user.id
      refute conn.halted
    end

    test "returns 401 when the session token is expired or invalid" do
      conn =
        build_conn()
        |> put_bearer(Base.url_encode64("not_a_real_token", padding: false))
        |> Auth.call(Auth.init([]))

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 when the token is not valid base64" do
      conn =
        build_conn()
        |> put_bearer("not!valid$base64%%%")
        |> Auth.call(Auth.init([]))

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "call/2 — missing header" do
    test "returns 401 when no Authorization header is present" do
      conn = Auth.call(build_conn(), Auth.init([]))

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 when Authorization header is not Bearer" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
        |> Auth.call(Auth.init([]))

      assert conn.status == 401
      assert conn.halted
    end
  end
end
