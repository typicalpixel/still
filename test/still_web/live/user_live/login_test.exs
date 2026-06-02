defmodule StillWeb.UserLive.LoginTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.AccountsFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      user_fixture()

      {:ok, _lv, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Log in to Still"
      assert html =~ "Email"
      assert html =~ "Password"
    end

    test "redirects to bootstrap when the instance has no users", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/bootstrap"}}} =
               live(conn, ~p"/users/log-in")
    end
  end

  describe "user login" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{conn: conn} do
      user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form = form(lv, "#login_form", user: %{email: "test@email.com", password: "123456"})

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
