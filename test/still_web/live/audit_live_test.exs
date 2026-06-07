defmodule StillWeb.AuditLiveTest do
  use StillWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Still.AuditFixtures

  alias Still.AccountsFixtures

  defp log_in_admin(%{conn: conn}) do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  describe "as an admin" do
    setup :log_in_admin

    test "renders the audit log with preset filters", %{conn: conn} do
      audit_event_fixture(%{type: "application_created", subject_type: :application})

      {:ok, lv, html} = live(conn, ~p"/settings/audit")

      assert html =~ "Audit log"
      assert html =~ "application created"

      for preset <- ~w(applications servers users auth all) do
        assert lv |> element("button[phx-value-preset=#{preset}]") |> render_click() =~
                 "Audit log"
      end
    end

    test "paginates older events with load more", %{conn: conn} do
      base = ~U[2026-01-01 00:00:00.000000Z]

      # 26 events — one past the 25-per-page window — so a second page exists.
      for i <- 0..25 do
        audit_event_fixture(%{
          type: "user_created",
          subject_type: :user,
          subject_id: Ecto.UUID.generate(),
          inserted_at: DateTime.add(base, -i, :second)
        })
      end

      {:ok, lv, html} = live(conn, ~p"/settings/audit")

      assert html =~ "Load more"
      refute html =~ "End of log"

      html = lv |> element("button", "Load more") |> render_click()

      refute html =~ "Load more"
      assert html =~ "End of log"
    end

    test "expands an audit event to its detail", %{conn: conn} do
      event =
        audit_event_fixture(%{
          type: "application_created",
          subject_type: :application,
          subject_id: Ecto.UUID.generate(),
          payload: %{"name" => "api"}
        })

      {:ok, lv, _html} = live(conn, ~p"/settings/audit")

      assert lv |> element(~s{button[phx-value-id="#{event.id}"]}) |> render_click() =~ "▾"
      refute lv |> element(~s{button[phx-value-id="#{event.id}"]}) |> render_click() =~ "▾"
    end
  end

  describe "as a viewer" do
    setup :register_and_log_in_user

    test "is redirected home without admin access", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/audit")
    end
  end
end
