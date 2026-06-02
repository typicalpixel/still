defmodule StillWeb.AccountLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Still.AccountsFixtures

  describe "account" do
    setup :register_and_log_in_user

    test "renders the profile, password, and appearance cards", %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/account")

      assert html =~ "Account"
      assert html =~ user.name
      assert html =~ user.email
      assert html =~ to_string(user.role)
      assert html =~ user.id
      assert html =~ "Password"
      assert html =~ "Appearance"
      assert html =~ "Theme"
    end

    test "edits the display name", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      lv |> element("button", "Edit") |> render_click()
      html = lv |> form("#profile-form", account: %{name: "New Name"}) |> render_submit()

      assert html =~ "Profile updated"
      assert html =~ "New Name"
    end

    test "surfaces profile validation errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      lv |> element("button", "Edit") |> render_click()
      html = lv |> form("#profile-form", account: %{name: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "opens then cancels the profile dialog", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      assert lv |> element("button", "Edit") |> render_click() =~ "Edit profile"
      refute lv |> element("#edit-profile button", "Cancel") |> render_click() =~ "Edit profile"
    end

    test "closes the profile dialog on Escape", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      assert lv |> element("button", "Edit") |> render_click() =~ "Edit profile"

      refute lv |> element("#edit-profile") |> render_keydown(%{"key" => "escape"}) =~
               "Edit profile"
    end

    test "changes the password and ends on the login page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      lv |> element("button", "Change") |> render_click()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               lv
               |> form("#password-form",
                 account: %{
                   current_password: AccountsFixtures.valid_user_password(),
                   password: "supersecret12",
                   password_confirmation: "supersecret12"
                 }
               )
               |> render_submit()
    end

    test "rejects a wrong current password", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      lv |> element("button", "Change") |> render_click()

      html =
        lv
        |> form("#password-form",
          account: %{
            current_password: "wrong-password",
            password: "supersecret12",
            password_confirmation: "supersecret12"
          }
        )
        |> render_submit()

      assert html =~ "Current password is incorrect."
    end

    test "rejects a mismatched confirmation", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      lv |> element("button", "Change") |> render_click()

      html =
        lv
        |> form("#password-form",
          account: %{
            current_password: AccountsFixtures.valid_user_password(),
            password: "supersecret12",
            password_confirmation: "different12345"
          }
        )
        |> render_submit()

      assert html =~ "Passwords must match"
    end

    test "surfaces new-password validation errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      lv |> element("button", "Change") |> render_click()

      html =
        lv
        |> form("#password-form",
          account: %{
            current_password: AccountsFixtures.valid_user_password(),
            password: "short",
            password_confirmation: "short"
          }
        )
        |> render_submit()

      assert html =~ "at least"
    end

    test "opens then cancels the password dialog", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/account")

      assert lv |> element("button", "Change") |> render_click() =~ "Change password"

      refute lv |> element("#change-password button", "Cancel") |> render_click() =~
               "Change password"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/account")
      assert path == ~p"/users/log-in"
    end
  end
end
