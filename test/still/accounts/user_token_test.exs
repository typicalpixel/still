defmodule Still.Accounts.UserTokenTest do
  use Still.DataCase, async: false

  alias Still.Accounts.UserToken
  alias Still.Repo

  import Still.AccountsFixtures

  describe "build_session_token/1" do
    test "returns a 32-byte random token paired with a session UserToken struct" do
      user = user_fixture()

      {token, user_token} = UserToken.build_session_token(user)

      assert is_binary(token)
      assert byte_size(token) == 32
      assert %UserToken{token: ^token, context: "session", user_id: user_id} = user_token
      assert user_id == user.id
    end

    test "produces a different token on each call" do
      user = user_fixture()

      {token1, _} = UserToken.build_session_token(user)
      {token2, _} = UserToken.build_session_token(user)

      refute token1 == token2
    end
  end

  describe "verify_session_token_query/1" do
    test "loads the user when the token is valid and not expired" do
      user = user_fixture()
      {token, user_token} = UserToken.build_session_token(user)
      Repo.insert!(user_token)

      assert [{loaded, %DateTime{}}] = Repo.all(UserToken.verify_session_token_query(token))
      assert loaded.id == user.id
    end

    test "returns no rows for an unknown token" do
      _ = user_fixture()

      assert [] == Repo.all(UserToken.verify_session_token_query(:crypto.strong_rand_bytes(32)))
    end

    test "returns no rows for a token older than the validity window" do
      user = user_fixture()
      {token, user_token} = UserToken.build_session_token(user)

      stale_inserted_at = DateTime.add(DateTime.utc_now(), -61, :day)

      Repo.insert!(%{user_token | inserted_at: stale_inserted_at})

      assert [] == Repo.all(UserToken.verify_session_token_query(token))
    end

    test "returns no rows when the row exists with a non-session context" do
      user = user_fixture()
      raw = :crypto.strong_rand_bytes(32)

      Repo.insert!(%UserToken{token: raw, context: "other", user_id: user.id})

      assert [] == Repo.all(UserToken.verify_session_token_query(raw))
    end
  end

  describe "by_token_and_context_query/2" do
    test "returns the matching row" do
      user = user_fixture()
      raw = :crypto.strong_rand_bytes(32)
      Repo.insert!(%UserToken{token: raw, context: "session", user_id: user.id})

      assert [_] = Repo.all(UserToken.by_token_and_context_query(raw, "session"))
      assert [] == Repo.all(UserToken.by_token_and_context_query(raw, "other"))
    end
  end
end
