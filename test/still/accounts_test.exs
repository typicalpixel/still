defmodule Still.AccountsTest do
  use Still.DataCase, async: false

  alias Still.Accounts
  alias Still.Accounts.ApiKey
  alias Still.Accounts.Scope
  alias Still.Accounts.User
  alias Still.Accounts.UserToken
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Repo

  import Still.AccountsFixtures

  describe "create_user/1" do
    test "persists a user with valid attributes" do
      attrs = %{
        email: "alice@example.com",
        name: "Alice",
        role: :admin,
        password: valid_user_password()
      }

      assert {:ok, %User{} = user} = Accounts.create_user(Actor.system(), attrs)
      assert user.id
      assert user.email == "alice@example.com"
      assert user.name == "Alice"
      assert user.role == :admin
      assert is_binary(user.hashed_password)
      refute user.hashed_password == valid_user_password()
    end

    test "lowercases the email on insert" do
      assert {:ok, user} =
               Accounts.create_user(Actor.system(), %{
                 email: "Alice@Example.COM",
                 name: "Alice",
                 role: :viewer,
                 password: valid_user_password()
               })

      assert user.email == "alice@example.com"
    end

    test "returns an error changeset for invalid attributes" do
      assert {:error, changeset} = Accounts.create_user(Actor.system(), %{})
      assert %{email: _, name: _, role: _, password: _} = errors_on(changeset)
    end

    test "rejects a duplicate email (case-insensitive)" do
      _existing = user_fixture(email: "alice@example.com")

      assert {:error, changeset} =
               Accounts.create_user(Actor.system(), %{
                 email: "ALICE@example.com",
                 name: "Other Alice",
                 role: :viewer,
                 password: valid_user_password()
               })

      assert "has already been taken" in errors_on(changeset).email
    end
  end

  describe "get_user_by_email_and_password/2" do
    setup do
      %{user: user_fixture(email: "alice@example.com")}
    end

    test "returns the user when credentials are valid", %{user: user} do
      assert %User{id: id} =
               Accounts.get_user_by_email_and_password("alice@example.com", valid_user_password())

      assert id == user.id
    end

    test "lowercases the lookup email" do
      assert %User{} =
               Accounts.get_user_by_email_and_password("ALICE@Example.com", valid_user_password())
    end

    test "returns nil when the password is wrong" do
      refute Accounts.get_user_by_email_and_password("alice@example.com", "wrong password!")
    end

    test "returns nil when the email is unknown" do
      refute Accounts.get_user_by_email_and_password("ghost@example.com", valid_user_password())
    end
  end

  describe "session tokens" do
    setup do
      %{user: user_fixture()}
    end

    test "generate_user_session_token/1 persists a session row and returns the raw token",
         %{user: user} do
      token = Accounts.generate_user_session_token(user)

      assert is_binary(token)
      assert byte_size(token) == 32

      assert %UserToken{context: "session", user_id: user_id} =
               Repo.get_by!(UserToken, token: token)

      assert user_id == user.id
    end

    test "get_user_by_session_token/1 returns the user and token timestamp for a valid token",
         %{user: user} do
      token = Accounts.generate_user_session_token(user)

      assert {%User{id: id}, %DateTime{}} = Accounts.get_user_by_session_token(token)
      assert id == user.id
    end

    test "get_user_by_session_token/1 returns nil for an unknown token" do
      refute Accounts.get_user_by_session_token(:crypto.strong_rand_bytes(32))
    end

    test "delete_user_session_token/1 removes the row and subsequent lookups return nil",
         %{user: user} do
      token = Accounts.generate_user_session_token(user)

      assert :ok = Accounts.delete_user_session_token(token)
      refute Accounts.get_user_by_session_token(token)
    end

    test "delete_user_session_token/1 returns :ok even when no row matches" do
      assert :ok = Accounts.delete_user_session_token(:crypto.strong_rand_bytes(32))
    end
  end

  describe "create_api_key/2" do
    setup do
      %{user: user_fixture()}
    end

    test "persists a key and returns the raw key on the struct", %{user: user} do
      assert {:ok, %ApiKey{} = api_key} =
               Accounts.create_api_key(Actor.system(), user, %{
                 name: "ci-deploy",
                 permissions: ["deploy", "read"]
               })

      assert api_key.id
      assert api_key.user_id == user.id
      assert api_key.name == "ci-deploy"
      assert api_key.permissions == ["deploy", "read"]
      assert is_binary(api_key.raw_key)
      assert String.starts_with?(api_key.raw_key, "still_")
      assert is_binary(api_key.hashed_key)
      assert api_key.hashed_key == ApiKey.hash_key(api_key.raw_key)
    end

    test "returns an error changeset for invalid attributes", %{user: user} do
      assert {:error, changeset} = Accounts.create_api_key(Actor.system(), user, %{})
      assert %{name: _, permissions: _} = errors_on(changeset)
    end

    test "ignores any user_id passed in attrs and uses the user's id", %{user: user} do
      other = user_fixture()

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{
          name: "scoped",
          permissions: ["read"],
          user_id: other.id
        })

      assert api_key.user_id == user.id
    end
  end

  describe "list_api_keys_for/1" do
    setup do
      user = user_fixture()
      other = user_fixture()
      %{user: user, other: other}
    end

    test "returns only the given user's keys, newest first", %{user: user, other: other} do
      _ = api_key_fixture(other, %{name: "other-key"})
      key1 = api_key_fixture(user, %{name: "first"})
      key2 = api_key_fixture(user, %{name: "second"})

      keys = Accounts.list_api_keys_for(user)
      ids = Enum.map(keys, & &1.id)

      assert key1.id in ids
      assert key2.id in ids
      assert length(keys) == 2
    end

    test "returns an empty list when the user has no keys", %{other: other} do
      assert [] == Accounts.list_api_keys_for(other)
    end
  end

  describe "get_user_by_api_key/1" do
    setup do
      user = user_fixture()
      api_key = api_key_fixture(user)
      %{user: user, api_key: api_key}
    end

    test "returns the user that owns the key", %{user: user, api_key: api_key} do
      assert %User{id: id} = Accounts.get_user_by_api_key(api_key.raw_key)
      assert id == user.id
    end

    test "returns nil for an unknown key" do
      refute Accounts.get_user_by_api_key("still_unknown")
    end
  end

  describe "delete_api_key/1" do
    test "removes the row" do
      user = user_fixture()
      api_key = api_key_fixture(user)

      assert {:ok, %ApiKey{}} = Accounts.delete_api_key(Actor.system(), api_key)
      refute Repo.get(ApiKey, api_key.id)
    end
  end

  describe "touch_api_key_used/1" do
    test "sets last_used_at to a real timestamp" do
      user = user_fixture()
      api_key = api_key_fixture(user)
      assert is_nil(api_key.last_used_at)

      assert {:ok, touched} = Accounts.touch_api_key_used(api_key)
      assert %DateTime{} = touched.last_used_at
      assert abs(DateTime.diff(DateTime.utc_now(), touched.last_used_at, :second)) < 5
    end
  end

  describe "audit trail" do
    setup do
      operator = user_fixture(%{email: "operator@example.com"})
      actor = Actor.from_scope(Scope.for_user(operator))
      %{actor: actor, operator: operator}
    end

    test "create_user records :user_created with after-snapshot, no password",
         %{actor: actor} do
      audit_count_before = length(Audit.list(type: :user_created))

      {:ok, created} =
        Accounts.create_user(actor, %{
          email: "audited@example.com",
          name: "Audited User",
          role: :viewer,
          password: valid_user_password()
        })

      audit_rows = Audit.list(type: :user_created)
      assert length(audit_rows) == audit_count_before + 1
      [event | _] = audit_rows

      assert event.subject_type == "user"
      assert event.subject_id == created.id
      assert event.actor_label == "operator@example.com"
      assert event.payload["email"] == "audited@example.com"
      assert event.before == nil

      # Redacted fields (hashed_password, virtual password) must never
      # appear in the snapshot — schemas declare them with `redact: true`.
      refute Map.has_key?(event.after, "password")
      refute Map.has_key?(event.after, "hashed_password")
    end

    test "create_api_key records :api_key_created with owner context, no key material",
         %{actor: actor, operator: operator} do
      audit_count_before = length(Audit.list(type: :api_key_created))

      {:ok, key} =
        Accounts.create_api_key(actor, operator, %{
          name: "ci-deploy",
          permissions: ["deploy"]
        })

      audit_rows = Audit.list(type: :api_key_created)
      assert length(audit_rows) == audit_count_before + 1
      [event | _] = audit_rows

      assert event.subject_type == "api_key"
      assert event.subject_id == key.id
      assert event.payload["api_key_name"] == "ci-deploy"
      assert event.payload["owner_email"] == "operator@example.com"
      assert event.payload["permissions"] == ["deploy"]

      # The hashed_key (binary, sensitive) and raw_key (virtual, the secret
      # itself) must never make it into the audit log — both are redacted.
      refute Map.has_key?(event.after, "hashed_key")
      refute Map.has_key?(event.after, "raw_key")
    end

    test "delete_api_key records :api_key_deleted with the before-snapshot",
         %{actor: actor, operator: operator} do
      key = api_key_fixture(operator, %{name: "to-revoke"})

      {:ok, _} = Accounts.delete_api_key(actor, key)

      assert [event] = Audit.list(type: :api_key_deleted)
      assert event.subject_id == key.id
      assert event.payload["owner_email"] == "operator@example.com"
      assert event.before["name"] == "to-revoke"
      assert event.after == nil
      refute Map.has_key?(event.before, "hashed_key")
    end

    test "failed mutation does not write an audit row", %{actor: actor} do
      audit_count_before = length(Audit.list(type: :user_created))

      assert {:error, %Ecto.Changeset{}} = Accounts.create_user(actor, %{})

      assert length(Audit.list(type: :user_created)) == audit_count_before
    end

    test "update_user records :user_updated with before/after", %{actor: actor} do
      user = user_fixture(%{email: "before@example.com", name: "Before", role: :viewer})

      {:ok, _} =
        Accounts.update_user(actor, user, %{
          email: "after@example.com",
          name: "After",
          role: :deployer
        })

      assert [event] = Audit.list(type: :user_updated)
      assert event.before["email"] == "before@example.com"
      assert event.after["email"] == "after@example.com"
      assert event.after["role"] == "deployer"
    end

    test "update_user_password records :user_password_changed without storing the password",
         %{actor: actor} do
      user = user_fixture()

      {:ok, _} = Accounts.update_user_password(actor, user, %{password: "fresh password 123"})

      assert [event] = Audit.list(type: :user_password_changed)
      assert event.subject_id == user.id
      # No before/after snapshots — the only field that changed is the
      # hashed password, which is redacted. Storing it (even hashed)
      # in the audit trail would defeat the purpose of redaction.
      assert is_nil(event.before)
      assert is_nil(event.after)
    end

    test "update_user_password deletes the user's session tokens and returns them",
         %{actor: actor} do
      user = user_fixture()
      token1 = Accounts.generate_user_session_token(user)
      token2 = Accounts.generate_user_session_token(user)

      {:ok, {_user, expired}} =
        Accounts.update_user_password(actor, user, %{password: "fresh password 123"})

      assert length(expired) == 2
      assert is_nil(Accounts.get_user_by_session_token(token1))
      assert is_nil(Accounts.get_user_by_session_token(token2))
    end

    test "delete_user records :user_deleted", %{actor: actor} do
      user = user_fixture(%{email: "departing@example.com"})

      {:ok, _} = Accounts.delete_user(actor, user)

      assert [event] = Audit.list(type: :user_deleted)
      assert event.before["email"] == "departing@example.com"
      assert event.after == nil
    end
  end

  describe "user CRUD guards" do
    test "delete_user refuses to delete the actor's own account" do
      user = user_fixture(%{role: :admin})
      actor = Actor.from_scope(Scope.for_user(user))

      assert {:error, :cannot_delete_self} = Accounts.delete_user(actor, user)
      assert %User{} = Accounts.get_user!(user.id)
    end

    test "delete_user refuses to delete the last admin" do
      sole_admin = user_fixture(%{role: :admin})
      _viewer = user_fixture(%{role: :viewer})

      # Use a system actor so the "self" guard doesn't fire first.
      assert {:error, :last_admin} = Accounts.delete_user(Actor.system(), sole_admin)
      assert %User{} = Accounts.get_user!(sole_admin.id)
    end

    test "delete_user succeeds when another admin remains" do
      admin1 = user_fixture(%{role: :admin})
      _admin2 = user_fixture(%{role: :admin})

      assert {:ok, _} = Accounts.delete_user(Actor.system(), admin1)
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(admin1.id) end
    end

    test "update_user refuses to demote the last admin" do
      sole_admin = user_fixture(%{role: :admin, email: "only@example.com"})

      assert {:error, :last_admin} =
               Accounts.update_user(Actor.system(), sole_admin, %{
                 email: sole_admin.email,
                 name: sole_admin.name,
                 role: :viewer
               })

      reloaded = Accounts.get_user!(sole_admin.id)
      assert reloaded.role == :admin
    end

    test "update_user allows demoting an admin when another admin exists" do
      admin1 = user_fixture(%{role: :admin})
      _admin2 = user_fixture(%{role: :admin})

      assert {:ok, demoted} =
               Accounts.update_user(Actor.system(), admin1, %{
                 email: admin1.email,
                 name: admin1.name,
                 role: :deployer
               })

      assert demoted.role == :deployer
    end

    test "update_user accepts a string role passed through (matches controller params)" do
      sole_admin = user_fixture(%{role: :admin, name: "Original"})

      assert {:ok, updated} =
               Accounts.update_user(Actor.system(), sole_admin, %{
                 "email" => sole_admin.email,
                 "name" => "Renamed",
                 "role" => "admin"
               })

      assert updated.role == :admin
      assert updated.name == "Renamed"
    end

    test "update_user treats a garbage role string as no-change (changeset rejects it)" do
      sole_admin = user_fixture(%{role: :admin})

      # The role-floor check sees `nil` (unrecognized string) and lets
      # the request through to the changeset, which fails validation
      # since :role is a required Ecto.Enum.
      assert {:error, %Ecto.Changeset{}} =
               Accounts.update_user(Actor.system(), sole_admin, %{
                 "email" => sole_admin.email,
                 "name" => sole_admin.name,
                 "role" => "godmode"
               })
    end

    test "update_user allows other field changes on a sole admin (just not role demotion)" do
      sole_admin = user_fixture(%{role: :admin, name: "Old Name"})

      assert {:ok, updated} =
               Accounts.update_user(Actor.system(), sole_admin, %{
                 email: sole_admin.email,
                 name: "New Name",
                 role: :admin
               })

      assert updated.name == "New Name"
      assert updated.role == :admin
    end
  end
end
