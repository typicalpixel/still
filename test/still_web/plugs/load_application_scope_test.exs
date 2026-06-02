defmodule StillWeb.Plugs.LoadApplicationScopeTest do
  use Still.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]

  alias Still.Accounts.Scope
  alias StillWeb.Plugs.LoadApplicationScope

  import Still.ApplicationsFixtures

  defp call_with(params, assigns \\ %{}) do
    conn = %{build_conn() | path_params: params}

    conn =
      Enum.reduce(assigns, conn, fn {k, v}, acc -> Plug.Conn.assign(acc, k, v) end)

    LoadApplicationScope.call(conn, LoadApplicationScope.init([]))
  end

  describe "call/2" do
    test "puts the application on an existing authenticated scope" do
      app = application_fixture(%{name: "api"})
      scope = Scope.for_user(%Still.Accounts.User{email: "a@b.c"})

      conn = call_with(%{"application_name" => app.name}, %{current_scope: scope})

      assert conn.assigns.current_scope.application.id == app.id
      assert conn.assigns.current_scope.user.email == "a@b.c"
      refute conn.halted
    end

    test "falls back to a fresh system scope when no scope is assigned yet" do
      app = application_fixture(%{name: "api-2"})

      conn = call_with(%{"application_name" => app.name})

      assert conn.assigns.current_scope.application.id == app.id
      assert is_nil(conn.assigns.current_scope.user)
    end

    test "halts with 404 JSON when the parent application does not exist" do
      conn = call_with(%{"application_name" => "no-such-app"})

      assert conn.halted
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["message"] == "Application not found"
    end
  end
end
