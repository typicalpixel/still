defmodule StillWeb.UserJSON do
  @moduledoc """
  JSON serialization for user records. Handpicks fields explicitly so
  the password hash and any future sensitive columns can never leak by
  accident — even if a future migration adds something we forget about.
  """

  alias Still.Accounts.User

  @doc "Renders a list of users."
  def render(users) when is_list(users) do
    %{data: Enum.map(users, &user/1)}
  end

  @doc "Renders a single user under the standard `data` envelope."
  def render_one(%User{} = user) do
    %{data: user(user)}
  end

  @doc "Base shape for a single user."
  def user(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      role: user.role,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
