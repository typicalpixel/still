defmodule StillWeb.UsersLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Still.AccountsFixtures

  defp log_in_admin(%{conn: conn}) do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp user(attrs), do: AccountsFixtures.user_fixture(attrs)

  describe "as an admin" do
    setup :log_in_admin

    test "lists users, flags you, and hides self-delete", %{conn: conn, admin: admin} do
      other = user(%{email: "bob@example.com", name: "Bob"})

      {:ok, lv, html} = live(conn, ~p"/users")

      assert html =~ admin.email
      assert html =~ "bob@example.com"
      assert html =~ "Bob"
      assert html =~ "you"
      assert html =~ "Create user"
      refute has_element?(lv, "#user-#{admin.id} button", "Delete")
      assert has_element?(lv, "#user-#{other.id} button", "Delete")
    end

    test "creates a user", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users")

      lv |> element("button", "Create user") |> render_click()
      lv |> element("#user-form-form button", "deployer") |> render_click()

      html =
        lv
        |> form("#user-form-form",
          user: %{name: "Bob", email: "bob@example.com", password: "supersecret12"}
        )
        |> render_submit()

      assert html =~ "bob@example.com created"
      assert html =~ "deployer"
    end

    test "surfaces create validation errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users")

      lv |> element("button", "Create user") |> render_click()

      html =
        lv
        |> form("#user-form-form",
          user: %{name: "Bob", email: "bob@example.com", password: "short"}
        )
        |> render_submit()

      assert html =~ "at least"
    end

    test "opens then cancels the create dialog", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users")

      assert lv |> element("button", "Create user") |> render_click() =~ "Create a user"
      refute lv |> element("#user-form button", "Cancel") |> render_click() =~ "Create a user"
    end

    test "edits a user", %{conn: conn} do
      other = user(%{email: "bob@example.com", name: "Bob"})

      {:ok, lv, _html} = live(conn, ~p"/users")

      lv |> element("#user-#{other.id} button", "Edit") |> render_click()
      lv |> element("#user-form-form button", "deployer") |> render_click()

      html =
        lv
        |> form("#user-form-form", user: %{name: "Bobby", email: "bob@example.com"})
        |> render_submit()

      assert html =~ "bob@example.com updated"
      assert html =~ "Bobby"
      assert html =~ "deployer"
    end

    test "refuses to demote the last admin", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/users")

      lv |> element("#user-#{admin.id} button", "Edit") |> render_click()
      lv |> element("#user-form-form button", "viewer") |> render_click()

      html =
        lv
        |> form("#user-form-form", user: %{name: admin.name, email: admin.email})
        |> render_submit()

      assert html =~ "Refusing to remove the last admin"
    end

    test "surfaces edit validation errors", %{conn: conn} do
      other = user(%{email: "bob@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/users")

      lv |> element("#user-#{other.id} button", "Edit") |> render_click()
      html = lv |> form("#user-form-form", user: %{name: "Bob", email: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "resets a password", %{conn: conn} do
      other = user(%{email: "bob@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/users")

      lv |> element("#user-#{other.id} button", "Reset password") |> render_click()

      html =
        lv
        |> form("#reset-password-form",
          user: %{password: "supersecret12", password_confirmation: "supersecret12"}
        )
        |> render_submit()

      assert html =~ "bob@example.com password reset"
    end

    test "rejects a mismatched password confirmation", %{conn: conn} do
      other = user(%{email: "bob@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/users")

      lv |> element("#user-#{other.id} button", "Reset password") |> render_click()

      html =
        lv
        |> form("#reset-password-form",
          user: %{password: "supersecret12", password_confirmation: "different12345"}
        )
        |> render_submit()

      assert html =~ "Passwords must match"
    end

    test "surfaces reset validation errors", %{conn: conn} do
      other = user(%{email: "bob@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/users")

      lv |> element("#user-#{other.id} button", "Reset password") |> render_click()

      html =
        lv
        |> form("#reset-password-form",
          user: %{password: "short", password_confirmation: "short"}
        )
        |> render_submit()

      assert html =~ "at least"
    end

    test "opens then cancels the reset dialog", %{conn: conn} do
      other = user(%{email: "bob@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/users")

      assert lv |> element("#user-#{other.id} button", "Reset password") |> render_click() =~
               "Reset password for"

      refute lv |> element("#reset-password button", "Cancel") |> render_click() =~
               "Reset password for"
    end

    test "deletes a user", %{conn: conn} do
      other = user(%{email: "bob@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/users")

      lv |> element("#user-#{other.id} button", "Delete") |> render_click()
      assert render(lv) =~ "Their sessions and API keys"

      html = lv |> element("#delete-user button", "Delete") |> render_click()
      assert html =~ "bob@example.com deleted"
      assert html =~ "1 total"
    end

    test "refuses to delete your own account", %{conn: conn, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/users")

      # The self-delete affordance is hidden in the UI; the guard still holds if forced.
      render_hook(lv, "open_delete", %{"id" => admin.id})
      html = lv |> element("#delete-user button", "Delete") |> render_click()

      assert html =~ "You cannot delete your own account"
    end

    test "opens then cancels the delete dialog", %{conn: conn} do
      other = user(%{email: "bob@example.com"})

      {:ok, lv, _html} = live(conn, ~p"/users")

      assert lv |> element("#user-#{other.id} button", "Delete") |> render_click() =~
               "Their sessions and API keys"

      refute lv |> element("#delete-user button", "Cancel") |> render_click() =~
               "Their sessions and API keys"
    end
  end

  describe "as a viewer" do
    setup :register_and_log_in_user

    test "is redirected to the dashboard", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/users")
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/users")
      assert path == ~p"/users/log-in"
    end
  end
end
