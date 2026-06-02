defmodule Still.Accounts.ApiKeyTest do
  use Still.DataCase, async: false

  alias Still.Accounts.ApiKey

  import Still.AccountsFixtures

  describe "creation_changeset/2" do
    setup do
      %{user: user_fixture()}
    end

    test "is valid with name, permissions, and user_id", %{user: user} do
      changeset =
        ApiKey.creation_changeset(%ApiKey{}, %{
          name: "ci-deploy",
          permissions: ["deploy", "read"],
          user_id: user.id
        })

      assert changeset.valid?
    end

    test "generates a raw_key with the still_ prefix and a hashed_key", %{user: user} do
      changeset =
        ApiKey.creation_changeset(%ApiKey{}, %{
          name: "ci-deploy",
          permissions: ["deploy"],
          user_id: user.id
        })

      raw_key = get_change(changeset, :raw_key)
      hashed_key = get_change(changeset, :hashed_key)

      assert String.starts_with?(raw_key, "still_")
      assert is_binary(hashed_key)
      assert byte_size(hashed_key) == 32
      assert hashed_key == ApiKey.hash_key(raw_key)
    end

    test "generates a different key on each call", %{user: user} do
      cs1 =
        ApiKey.creation_changeset(%ApiKey{}, %{
          name: "a",
          permissions: ["read"],
          user_id: user.id
        })

      cs2 =
        ApiKey.creation_changeset(%ApiKey{}, %{
          name: "b",
          permissions: ["read"],
          user_id: user.id
        })

      refute get_change(cs1, :raw_key) == get_change(cs2, :raw_key)
    end

    test "requires name and permissions" do
      changeset = ApiKey.creation_changeset(%ApiKey{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.permissions
    end

    test "validates name length bounds", %{user: user} do
      empty =
        ApiKey.creation_changeset(%ApiKey{}, %{
          name: "",
          permissions: ["read"],
          user_id: user.id
        })

      assert "can't be blank" in errors_on(empty).name

      too_long =
        ApiKey.creation_changeset(%ApiKey{}, %{
          name: String.duplicate("x", 101),
          permissions: ["read"],
          user_id: user.id
        })

      assert "should be at most 100 character(s)" in errors_on(too_long).name
    end

    test "rejects unknown permissions", %{user: user} do
      changeset =
        ApiKey.creation_changeset(%ApiKey{}, %{
          name: "bad",
          permissions: ["read", "wreck-the-database"],
          user_id: user.id
        })

      assert "has an invalid entry" in errors_on(changeset).permissions
    end

    test "accepts each individually-valid permission", %{user: user} do
      for perm <- ApiKey.valid_permissions() do
        changeset =
          ApiKey.creation_changeset(%ApiKey{}, %{
            name: "ok-#{perm}",
            permissions: [perm],
            user_id: user.id
          })

        assert changeset.valid?, "expected #{perm} to be a valid permission"
      end
    end

    test "rejects an empty permissions list", %{user: user} do
      changeset =
        ApiKey.creation_changeset(%ApiKey{}, %{
          name: "empty",
          permissions: [],
          user_id: user.id
        })

      assert "must include at least one permission" in errors_on(changeset).permissions
    end
  end

  describe "hash_key/1" do
    test "returns a 32-byte SHA256 digest" do
      hash = ApiKey.hash_key("still_abc")
      assert is_binary(hash)
      assert byte_size(hash) == 32
    end

    test "is deterministic for the same input" do
      assert ApiKey.hash_key("still_abc") == ApiKey.hash_key("still_abc")
    end

    test "produces different output for different input" do
      refute ApiKey.hash_key("still_a") == ApiKey.hash_key("still_b")
    end
  end

  describe "valid_permissions/0" do
    test "returns the known permission set" do
      assert ApiKey.valid_permissions() == ~w(admin deploy rollback read)
    end
  end

  describe "touch_changeset/2" do
    test "stamps the given timestamp on last_used_at" do
      now = DateTime.utc_now()
      changeset = ApiKey.touch_changeset(%ApiKey{}, now)

      assert get_change(changeset, :last_used_at) == now
    end
  end
end
