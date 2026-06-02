defmodule Still.Audit.ActorTest do
  use Still.DataCase, async: false

  alias Still.Accounts
  alias Still.Accounts.Scope
  alias Still.Audit.Actor

  import Plug.Test, only: [conn: 3]
  import Still.AccountsFixtures

  describe "kinds/0" do
    test "lists every supported actor kind" do
      assert Actor.kinds() == [:user, :api_key, :agent, :anonymous, :system]
    end
  end

  describe "anonymous/0" do
    test "returns an anonymous actor with no identity fields" do
      actor = Actor.anonymous()

      assert %Actor{kind: :anonymous, label: "anonymous"} = actor
      assert is_nil(actor.user_id)
      assert is_nil(actor.api_key_id)
    end
  end

  describe "from_scope/1 with synthetic users" do
    test "falls back to user:<id> when the user has no email" do
      uid = Ecto.UUID.generate()
      scope = Scope.for_user(%Still.Accounts.User{id: uid, role: :viewer})

      actor = Actor.from_scope(scope)

      assert %Actor{kind: :user, label: label, user_id: ^uid} = actor
      assert label == "user:#{uid}"
    end
  end

  describe "system/0" do
    test "returns a system actor with no identity fields" do
      actor = Actor.system()

      assert %Actor{kind: :system, label: "system"} = actor
      assert is_nil(actor.user_id)
      assert is_nil(actor.api_key_id)
      assert is_nil(actor.server_id)
    end
  end

  describe "agent/2" do
    test "builds an agent actor from id and name" do
      actor = Actor.agent("srv-1", "edge-01")

      assert %Actor{kind: :agent, label: "agent:edge-01", server_id: "srv-1"} = actor
    end
  end

  describe "from_scope/1" do
    test "builds a :user actor from a session-token scope" do
      user = user_fixture(%{email: "ops@example.com"})
      scope = Scope.for_user(user)

      actor = Actor.from_scope(scope)

      assert %Actor{kind: :user, label: "ops@example.com", user_id: id} = actor
      assert id == user.id
      assert is_nil(actor.api_key_id)
    end

    test "builds an :api_key actor when the scope has an API key" do
      user = user_fixture(%{email: "ci@example.com"})

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "ci", permissions: ["read"]})

      scope = user |> Scope.for_user() |> Scope.put_api_key(api_key)

      actor = Actor.from_scope(scope)

      assert %Actor{
               kind: :api_key,
               label: "key:ci (ci@example.com)",
               user_id: uid,
               api_key_id: kid
             } = actor

      assert uid == user.id
      assert kid == api_key.id
    end

    test "falls back to anonymous when the scope is empty" do
      assert %Actor{kind: :anonymous} = Actor.from_scope(Scope.for_system())
    end
  end

  describe "from_conn/1" do
    test "captures user, IP, and user-agent from a conn with a scope" do
      user = user_fixture(%{email: "user@example.com"})
      scope = Scope.for_user(user)

      conn =
        :get
        |> conn("/api/whatever", "")
        |> Plug.Conn.assign(:current_scope, scope)
        |> Plug.Conn.put_req_header("user-agent", "still/test")
        |> Map.put(:remote_ip, {10, 0, 0, 7})

      actor = Actor.from_conn(conn)

      assert %Actor{
               kind: :user,
               label: "user@example.com",
               ip: "10.0.0.7",
               user_agent: "still/test"
             } = actor
    end

    test "returns an anonymous actor with IP/UA captured when the conn has no scope" do
      conn =
        :get
        |> conn("/api/whatever", "")
        |> Plug.Conn.put_req_header("user-agent", "curl/8")
        |> Map.put(:remote_ip, {127, 0, 0, 1})

      actor = Actor.from_conn(conn)

      assert %Actor{kind: :anonymous, ip: "127.0.0.1", user_agent: "curl/8"} = actor
    end

    test "leaves ip and user-agent nil when the conn has neither" do
      conn =
        :get
        |> conn("/api/whatever", "")
        |> Map.put(:remote_ip, nil)

      actor = Actor.from_conn(conn)

      assert %Actor{kind: :anonymous, ip: nil, user_agent: nil} = actor
    end
  end
end
