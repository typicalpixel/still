defmodule Still.Accounts.ScopeTest do
  use Still.DataCase, async: false

  alias Still.Accounts.Scope
  alias Still.Accounts.User
  alias Still.Applications.Application

  describe "for_user/1" do
    test "wraps a %User{} in a scope" do
      user = %User{email: "alice@example.com"}
      assert %Scope{user: ^user, application: nil} = Scope.for_user(user)
    end

    test "returns nil for nil" do
      assert is_nil(Scope.for_user(nil))
    end
  end

  describe "for_system/0" do
    test "builds an empty scope with no user and no application" do
      assert %Scope{user: nil, application: nil} = Scope.for_system()
    end
  end

  describe "put_application/2" do
    test "attaches an application to an existing scope" do
      scope = Scope.for_system()
      app = %Application{name: "api"}
      assert %Scope{application: ^app} = Scope.put_application(scope, app)
    end
  end

  describe "put_api_key/2" do
    test "attaches an API key to an existing scope" do
      scope = Scope.for_user(%User{email: "a@b.c"})
      api_key = %Still.Accounts.ApiKey{permissions: ["read"]}
      assert %Scope{api_key: ^api_key} = Scope.put_api_key(scope, api_key)
    end

    test "is a no-op when the api_key is nil (session-token auth)" do
      scope = Scope.for_user(%User{email: "a@b.c"})
      assert %Scope{api_key: nil} = Scope.put_api_key(scope, nil)
    end
  end

  describe "can?/2 — user role path (no API key)" do
    test "admin user covers every permission level" do
      scope = Scope.for_user(%User{role: :admin})
      assert Scope.can?(scope, :read)
      assert Scope.can?(scope, :rollback)
      assert Scope.can?(scope, :deploy)
      assert Scope.can?(scope, :admin)
    end

    test "deployer user covers read/rollback/deploy but not admin" do
      scope = Scope.for_user(%User{role: :deployer})
      assert Scope.can?(scope, :read)
      assert Scope.can?(scope, :rollback)
      assert Scope.can?(scope, :deploy)
      refute Scope.can?(scope, :admin)
    end

    test "viewer user only covers read" do
      scope = Scope.for_user(%User{role: :viewer})
      assert Scope.can?(scope, :read)
      refute Scope.can?(scope, :rollback)
      refute Scope.can?(scope, :deploy)
      refute Scope.can?(scope, :admin)
    end
  end

  describe "can?/2 — API key path overrides user role" do
    test "admin key grants every permission regardless of owner role" do
      scope =
        %User{role: :viewer}
        |> Scope.for_user()
        |> Scope.put_api_key(%Still.Accounts.ApiKey{permissions: ["admin"]})

      assert Scope.can?(scope, :read)
      assert Scope.can?(scope, :rollback)
      assert Scope.can?(scope, :deploy)
      assert Scope.can?(scope, :admin)
    end

    test "deploy key covers read/rollback/deploy but not admin" do
      scope =
        %User{role: :admin}
        |> Scope.for_user()
        |> Scope.put_api_key(%Still.Accounts.ApiKey{permissions: ["deploy"]})

      assert Scope.can?(scope, :read)
      assert Scope.can?(scope, :rollback)
      assert Scope.can?(scope, :deploy)
      refute Scope.can?(scope, :admin)
    end

    test "rollback key covers read/rollback but not deploy" do
      scope =
        %User{role: :admin}
        |> Scope.for_user()
        |> Scope.put_api_key(%Still.Accounts.ApiKey{permissions: ["rollback"]})

      assert Scope.can?(scope, :read)
      assert Scope.can?(scope, :rollback)
      refute Scope.can?(scope, :deploy)
      refute Scope.can?(scope, :admin)
    end

    test "read key covers read only" do
      scope =
        %User{role: :admin}
        |> Scope.for_user()
        |> Scope.put_api_key(%Still.Accounts.ApiKey{permissions: ["read"]})

      assert Scope.can?(scope, :read)
      refute Scope.can?(scope, :rollback)
      refute Scope.can?(scope, :deploy)
      refute Scope.can?(scope, :admin)
    end

    test "key with multiple permissions grants the union" do
      scope =
        %User{role: :admin}
        |> Scope.for_user()
        |> Scope.put_api_key(%Still.Accounts.ApiKey{permissions: ["read", "rollback"]})

      assert Scope.can?(scope, :read)
      assert Scope.can?(scope, :rollback)
      refute Scope.can?(scope, :deploy)
      refute Scope.can?(scope, :admin)
    end
  end

  describe "can?/2 — empty scope" do
    test "system scope with no user never passes" do
      scope = Scope.for_system()
      refute Scope.can?(scope, :read)
      refute Scope.can?(scope, :rollback)
      refute Scope.can?(scope, :deploy)
      refute Scope.can?(scope, :admin)
    end

    test "nil is never authorized" do
      refute Scope.can?(nil, :read)
    end
  end
end
