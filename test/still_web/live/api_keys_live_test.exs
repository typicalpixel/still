defmodule StillWeb.ApiKeysLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Still.Accounts
  alias Still.AccountsFixtures
  alias Still.Audit.Actor

  defp log_in_admin(%{conn: conn}) do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp create_key(user, name) do
    Accounts.create_api_key(Actor.system(), user, %{"name" => name, "permissions" => ["read"]})
  end

  describe "as an admin" do
    setup :log_in_admin

    test "lists keys and shows the create affordance", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/api-keys")

      assert html =~ "API keys"
      assert html =~ "No API keys yet."
      assert html =~ "Create API key"
    end

    test "creates a key and reveals the raw value once", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      lv |> element("button", "Create API key") |> render_click()
      # Add a second permission on top of the default "read".
      lv |> element("#create-api-key-form button", "deploy") |> render_click()
      html = lv |> form("#create-api-key-form", api_key: %{name: "ci-bot"}) |> render_submit()

      assert html =~ "API key created"
      assert html =~ "only time"
      assert html =~ "still_"
      # The new key shows up in the list behind the dialog.
      assert html =~ "ci-bot"
    end

    test "requires at least one permission", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      lv |> element("button", "Create API key") |> render_click()
      # Toggle the default "read" permission off, leaving none selected.
      lv |> element("#create-api-key-form button", "read") |> render_click()
      html = lv |> form("#create-api-key-form", api_key: %{name: "ci-bot"}) |> render_submit()

      assert html =~ "Pick at least one permission."
    end

    test "surfaces changeset errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      lv |> element("button", "Create API key") |> render_click()
      html = lv |> form("#create-api-key-form", api_key: %{name: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "opens then cancels the create dialog", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      assert lv |> element("button", "Create API key") |> render_click() =~ "Create an API key"

      refute lv |> element("#create-api-key button", "Cancel") |> render_click() =~
               "Create an API key"
    end

    test "revokes a key", %{conn: conn, admin: admin} do
      {:ok, _key} = create_key(admin, "old-key")

      {:ok, lv, html} = live(conn, ~p"/api-keys")
      assert html =~ "old-key"

      lv |> element("#api-keys button", "Revoke") |> render_click()
      assert render(lv) =~ "Anything signed in with this key"

      html = lv |> element("#revoke-api-key button", "Revoke") |> render_click()
      assert html =~ "old-key revoked"
      assert html =~ "No API keys yet."
    end

    test "opens then cancels the revoke dialog", %{conn: conn, admin: admin} do
      {:ok, _key} = create_key(admin, "keep-me")

      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      assert lv |> element("#api-keys button", "Revoke") |> render_click() =~ "Anything signed in"

      refute lv |> element("#revoke-api-key button", "Cancel") |> render_click() =~
               "Anything signed in"
    end

    test "ignores a revoke event with no target open", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/api-keys")
      assert render_hook(lv, "revoke", %{}) =~ "API keys"
    end
  end

  describe "as a viewer" do
    setup :register_and_log_in_user

    test "hides the create and revoke affordances", %{conn: conn, user: user} do
      {:ok, _key} = create_key(user, "mykey")

      {:ok, _lv, html} = live(conn, ~p"/api-keys")

      assert html =~ "mykey"
      refute html =~ "Create API key"
      refute html =~ "Revoke"
    end

    test "rejects create and revoke without admin", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/api-keys")

      assert render_hook(lv, "create", %{"api_key" => %{"name" => "x"}}) =~
               "permission to create"

      assert render_hook(lv, "revoke", %{}) =~ "permission to revoke"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/api-keys")
      assert path == ~p"/users/log-in"
    end
  end
end
