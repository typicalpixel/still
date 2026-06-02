defmodule StillWeb.AuthJSON do
  @moduledoc """
  JSON serialization for auth endpoints — login responses and
  current-user lookups.
  """

  alias Still.Accounts.User

  @doc "Renders the login response — session token plus user."
  def render_login(token, %User{} = user) when is_binary(token) do
    %{data: %{token: token, user: user(user)}}
  end

  @doc "Renders the current-user response."
  def render_me(%User{} = user) do
    %{data: %{user: user(user)}}
  end

  @doc "Safe-to-return user fields."
  def user(%User{} = user) do
    %{id: user.id, email: user.email, name: user.name, role: user.role}
  end
end
