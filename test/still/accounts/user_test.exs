defmodule Still.Accounts.UserTest do
  use Still.DataCase, async: false

  alias Still.Accounts.User

  import Still.AccountsFixtures

  describe "registration_changeset/3" do
    test "is valid with all required attributes" do
      attrs = %{
        email: "alice@example.com",
        name: "Alice",
        role: :admin,
        password: valid_user_password()
      }

      changeset = User.registration_changeset(%User{}, attrs)

      assert changeset.valid?
    end

    test "requires email, name, role, and password" do
      changeset = User.registration_changeset(%User{}, %{})

      assert %{
               email: ["can't be blank"],
               name: ["can't be blank"],
               role: ["can't be blank"],
               password: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "validates email format" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "not-an-email",
          name: "Alice",
          role: :viewer,
          password: valid_user_password()
        })

      assert "must have the @ sign and no spaces" in errors_on(changeset).email
    end

    test "validates email length cap" do
      long_email = String.duplicate("a", 160) <> "@example.com"

      changeset =
        User.registration_changeset(%User{}, %{
          email: long_email,
          name: "Alice",
          role: :viewer,
          password: valid_user_password()
        })

      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "normalizes email to lowercase" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "Alice@Example.COM",
          name: "Alice",
          role: :viewer,
          password: valid_user_password()
        })

      assert get_change(changeset, :email) == "alice@example.com"
    end

    test "validates password minimum length" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "alice@example.com",
          name: "Alice",
          role: :viewer,
          password: "short"
        })

      assert "should be at least 12 character(s)" in errors_on(changeset).password
    end

    test "validates password maximum length" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "alice@example.com",
          name: "Alice",
          role: :viewer,
          password: String.duplicate("a", 73)
        })

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "validates name length bounds" do
      empty_name_changeset =
        User.registration_changeset(%User{}, %{
          email: "alice@example.com",
          name: "",
          role: :viewer,
          password: valid_user_password()
        })

      assert "can't be blank" in errors_on(empty_name_changeset).name

      long_name_changeset =
        User.registration_changeset(%User{}, %{
          email: "alice@example.com",
          name: String.duplicate("a", 101),
          role: :viewer,
          password: valid_user_password()
        })

      assert "should be at most 100 character(s)" in errors_on(long_name_changeset).name
    end

    test "rejects unknown roles" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "alice@example.com",
          name: "Alice",
          role: :superuser,
          password: valid_user_password()
        })

      assert "is invalid" in errors_on(changeset).role
    end

    test "accepts each valid role" do
      for role <- [:admin, :deployer, :viewer] do
        changeset =
          User.registration_changeset(%User{}, %{
            email: "user-#{role}@example.com",
            name: "User #{role}",
            role: role,
            password: valid_user_password()
          })

        assert changeset.valid?, "expected role #{inspect(role)} to be valid"
      end
    end

    test "hashes the password and clears the virtual field" do
      changeset =
        User.registration_changeset(%User{}, %{
          email: "alice@example.com",
          name: "Alice",
          role: :viewer,
          password: valid_user_password()
        })

      assert get_change(changeset, :hashed_password) != nil
      assert get_change(changeset, :password) == nil
    end

    test "with hash_password: false skips hashing" do
      changeset =
        User.registration_changeset(
          %User{},
          %{
            email: "alice@example.com",
            name: "Alice",
            role: :viewer,
            password: valid_user_password()
          },
          hash_password: false
        )

      assert get_change(changeset, :hashed_password) == nil
      assert get_change(changeset, :password) == valid_user_password()
    end

    test "with validate_email: false skips email format validation but still normalizes" do
      changeset =
        User.registration_changeset(
          %User{},
          %{
            email: "Not-An-Email",
            name: "Alice",
            role: :viewer,
            password: valid_user_password()
          },
          validate_email: false
        )

      refute Map.has_key?(errors_on(changeset), :email)
      assert get_change(changeset, :email) == "not-an-email"
    end
  end

  describe "valid_password?/2" do
    setup do
      %{user: user_fixture()}
    end

    test "returns true for the correct password", %{user: user} do
      assert User.valid_password?(user, valid_user_password())
    end

    test "returns false for an incorrect password", %{user: user} do
      refute User.valid_password?(user, "wrong password!")
    end

    test "returns false for a user with no hashed_password" do
      refute User.valid_password?(%User{hashed_password: nil}, valid_user_password())
    end

    test "returns false for an empty password", %{user: user} do
      refute User.valid_password?(user, "")
    end
  end
end
