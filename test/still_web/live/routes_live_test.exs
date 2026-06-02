defmodule StillWeb.RoutesLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Events

  describe "routes" do
    setup :register_and_log_in_user

    test "lists applications with their upstream dials", %{conn: conn} do
      app = application_fixture(%{name: "api", domain: "api.example.com"})
      server = server_fixture(%{name: "web-1", host: "10.0.0.1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      {:ok, _lv, html} = live(conn, ~p"/routes")

      assert html =~ "Routes"
      assert html =~ "1 application"
      assert html =~ "api"
      assert html =~ "api.example.com"
      assert html =~ "web-1"
      assert html =~ "10.0.0.1:"
    end

    test "shows the empty notice, then reloads when the fleet changes", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/routes")

      assert html =~ "No routes yet."
      assert html =~ "0 applications"

      app = application_fixture(%{name: "api"})
      server = server_fixture(%{name: "web-1", host: "10.0.0.1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)
      Events.fleet_changed()

      html = render(lv)
      assert html =~ "api"
      assert html =~ "10.0.0.1:"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/routes")
      assert path == ~p"/users/log-in"
    end
  end
end
