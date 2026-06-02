defmodule Still.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Still.Accounts` context.

  All fixtures accept an optional attrs map that will override the generated defaults.
  """

  import Ecto.Query

  alias Still.Accounts.UserToken
  alias Still.Audit.Actor
  alias Still.Repo

  @doc """
  Returns a valid plaintext password for use in tests.
  """
  def valid_user_password, do: "hello world!"

  @doc """
  Backdates the `inserted_at` of the given raw session token so token-reissue
  logic can be exercised. Returns the token.
  """
  def override_token_inserted_at(token, %DateTime{} = inserted_at) when is_binary(token) do
    Repo.update_all(
      from(t in UserToken, where: t.token == ^token),
      set: [inserted_at: inserted_at]
    )

    token
  end

  @doc """
  Generate a user.
  """
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{n}@example.com",
        name: "User #{n}",
        role: :viewer,
        password: valid_user_password()
      })
      |> then(&Still.Accounts.create_user(Actor.system(), &1))

    user
  end

  @doc """
  Generate an API key for the given user.
  """
  def api_key_fixture(%Still.Accounts.User{} = user, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, api_key} =
      attrs
      |> Enum.into(%{
        name: "key-#{n}",
        permissions: ["read"]
      })
      |> then(&Still.Accounts.create_api_key(Actor.system(), user, &1))

    api_key
  end
end
