defmodule StillWeb.BootstrapLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Still.Accounts
  alias Still.AccountsFixtures

  describe "fresh install" do
    test "creates the first admin and signs in", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/bootstrap")
      assert html =~ "Set up Still"

      form =
        form(lv, "#bootstrap-form",
          user: %{
            email: "admin@example.com",
            name: "Admin",
            password: "supersecret12",
            password_confirmation: "supersecret12"
          }
        )

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert Accounts.has_users?()
    end

    test "rejects mismatched passwords", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bootstrap")

      html =
        lv
        |> form("#bootstrap-form",
          user: %{
            email: "a@example.com",
            name: "A",
            password: "supersecret12",
            password_confirmation: "different12345"
          }
        )
        |> render_submit()

      assert html =~ "Passwords must match"
    end

    test "surfaces validation errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/bootstrap")

      html =
        lv
        |> form("#bootstrap-form",
          user: %{
            email: "a@example.com",
            name: "A",
            password: "short",
            password_confirmation: "short"
          }
        )
        |> render_submit()

      assert html =~ "at least"
    end
  end

  describe "already set up" do
    test "redirects to login when a user exists", %{conn: conn} do
      AccountsFixtures.user_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/bootstrap")
    end
  end
end
