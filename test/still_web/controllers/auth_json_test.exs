defmodule StillWeb.AuthJSONTest do
  use ExUnit.Case, async: true

  alias Still.Accounts.User
  alias StillWeb.AuthJSON

  defp sample_user do
    %User{id: "user-1", email: "jane@example.com", name: "Jane", role: :admin}
  end

  describe "user/1" do
    test "emits only safe fields" do
      shape = AuthJSON.user(sample_user())

      assert shape == %{id: "user-1", email: "jane@example.com", name: "Jane", role: :admin}
    end

    test "never exposes password hashes or token material" do
      user = %User{sample_user() | hashed_password: "$argon2id$v=..."}
      shape = AuthJSON.user(user)

      refute Map.has_key?(shape, :hashed_password)
    end
  end

  describe "render_login/2" do
    test "returns token and user under data" do
      assert %{data: %{token: "tok", user: %{id: "user-1"}}} =
               AuthJSON.render_login("tok", sample_user())
    end
  end

  describe "render_me/1" do
    test "returns the current user under data" do
      assert %{data: %{user: %{id: "user-1"}}} = AuthJSON.render_me(sample_user())
    end
  end
end
