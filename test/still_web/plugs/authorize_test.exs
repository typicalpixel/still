defmodule StillWeb.Plugs.AuthorizeTest do
  use Still.DataCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest, only: [build_conn: 0]

  alias Still.Accounts.ApiKey
  alias Still.Accounts.Scope
  alias Still.Accounts.User
  alias StillWeb.Plugs.Authorize

  describe "init/1" do
    test "accepts each supported permission atom" do
      for perm <- [:read, :rollback, :deploy, :admin] do
        assert Authorize.init(perm) == perm
      end
    end

    test "raises on an unsupported permission" do
      # apply/3 keeps the deliberately-invalid argument out of the type checker
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      assert_raise FunctionClauseError, fn -> apply(Authorize, :init, [:superuser]) end
    end
  end

  describe "call/2 — authorized" do
    test "passes through when the scope has the required permission" do
      scope =
        Scope.for_user(%User{role: :deployer})

      conn =
        build_conn()
        |> assign(:current_scope, scope)
        |> Authorize.call(:deploy)

      refute conn.halted
      assert conn.status == nil
    end

    test "passes through when an admin api key covers an admin route" do
      scope =
        %User{role: :viewer}
        |> Scope.for_user()
        |> Scope.put_api_key(%ApiKey{permissions: ["admin"]})

      conn =
        build_conn()
        |> assign(:current_scope, scope)
        |> Authorize.call(:admin)

      refute conn.halted
    end
  end

  describe "call/2 — forbidden" do
    test "halts with 403 when the scope is present but underpowered" do
      scope = Scope.for_user(%User{role: :viewer})

      conn =
        build_conn()
        |> assign(:current_scope, scope)
        |> Authorize.call(:deploy)

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"]["message"] == "Insufficient permissions"
      assert body["error"]["detail"]["required"] == "deploy"
    end

    test "halts with 403 when a read-only API key hits a deploy route" do
      scope =
        %User{role: :admin}
        |> Scope.for_user()
        |> Scope.put_api_key(%ApiKey{permissions: ["read"]})

      conn =
        build_conn()
        |> assign(:current_scope, scope)
        |> Authorize.call(:deploy)

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "call/2 — unauthorized" do
    test "halts with 401 when no scope has been installed on the conn" do
      # Conn has never been through the Auth plug — assigns is empty.
      conn = Authorize.call(build_conn(), :read)

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["message"] =~ "Missing or invalid"
    end
  end
end
