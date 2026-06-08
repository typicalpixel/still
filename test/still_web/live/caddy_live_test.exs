defmodule StillWeb.CaddyLiveTest do
  use StillWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Still.FleetFixtures

  alias Still.AccountsFixtures

  defp log_in_admin(%{conn: conn}) do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp stub_config(config) do
    Req.Test.stub(Still.Agent.CaddyManager, fn conn -> Req.Test.json(conn, config) end)
  end

  describe "as an admin" do
    setup :log_in_admin

    test "renders the controller's live Caddy config", %{conn: conn} do
      stub_config(%{
        "apps" => %{"http" => %{"servers" => %{"still" => %{"listen" => [":8080"]}}}}
      })

      {:ok, _lv, html} = live(conn, ~p"/caddy")

      assert html =~ "Caddy config"
      assert html =~ "still_internal" or html =~ "8080"
    end

    test "shows an error when Caddy's admin API is unreachable", %{conn: conn} do
      Req.Test.stub(Still.Agent.CaddyManager, fn c ->
        c |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      {:ok, _lv, html} = live(conn, ~p"/caddy")
      assert html =~ "Couldn&#39;t reach Caddy" or html =~ "Couldn't reach Caddy"
    end

    test "selecting a disconnected server reports the agent is not connected", %{conn: conn} do
      start_supervised!(Still.AgentConnectionManager)
      stub_config(%{"apps" => %{}})
      server = server_fixture(%{name: "edge-1"})
      # A second host makes it multi-node, so the node picker is shown.
      server_fixture(%{name: "edge-2"})

      {:ok, lv, _html} = live(conn, ~p"/caddy")

      html = lv |> element("form") |> render_change(%{"target" => server.id})
      assert html =~ "agent isn&#39;t connected" or html =~ "agent isn't connected"
    end
  end

  describe "as a non-admin" do
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture(%{role: :viewer})
      %{conn: log_in_user(conn, user)}
    end

    test "shows a forbidden notice and no config", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/caddy")
      assert html =~ "Admin permission is required"
    end
  end
end
