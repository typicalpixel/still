defmodule Still.Accounts.UserToken do
  @moduledoc """
  User token schema and queries for session tokens.
  """

  use Still.Schema

  import Ecto.Query

  alias Still.Accounts.UserToken

  @rand_size 32
  @session_validity_in_days 60

  schema "users_tokens" do
    field :token, :binary
    field :context, :string

    belongs_to :user, Still.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Builds an opaque session token along with its `UserToken` struct ready for insert.

  Returns a `{token, user_token}` tuple. The raw `token` is what callers
  should hand to the client; the `user_token` struct is what gets persisted.
  """
  def build_session_token(%Still.Accounts.User{} = user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    {token, %UserToken{token: token, context: "session", user_id: user.id}}
  end

  @doc """
  Returns the query for verifying a session token and loading the associated user.

  Yields a query that selects `{user, token_inserted_at}` only when the token
  exists, has the `"session"` context, and was inserted within the validity
  window. The timestamp lets callers decide whether to reissue an aging token.
  """
  def verify_session_token_query(token) when is_binary(token) do
    from t in by_token_and_context_query(token, "session"),
      join: u in assoc(t, :user),
      where: t.inserted_at > ago(@session_validity_in_days, "day"),
      select: {u, t.inserted_at}
  end

  @doc """
  Returns a query for the row matching the given token and context.
  """
  def by_token_and_context_query(token, context)
      when is_binary(token) and is_binary(context) do
    from UserToken, where: [token: ^token, context: ^context]
  end
end
