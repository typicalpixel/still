defmodule StillWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use StillWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Still.Accounts.Scope

  using do
    quote do
      # The default endpoint for testing
      @endpoint StillWeb.Endpoint

      use StillWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import StillWeb.ConnCase
    end
  end

  setup tags do
    Still.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in a user.

      setup :register_and_log_in_user

  Stores an updated connection, the user, and its scope in the test context.
  """
  def register_and_log_in_user(%{conn: conn}) do
    user = Still.AccountsFixtures.user_fixture()
    scope = Scope.for_user(user)
    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn` by putting a session token in the
  session, the way `StillWeb.UserAuth` reads it. Returns the updated `conn`.
  """
  def log_in_user(conn, user) do
    token = Still.Accounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
