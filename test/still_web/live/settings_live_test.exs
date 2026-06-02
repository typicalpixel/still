defmodule StillWeb.SettingsLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.AuditFixtures
  import Still.FleetFixtures

  alias Still.AccountsFixtures
  alias Still.AgentConnectionManager

  setup do
    start_supervised!(AgentConnectionManager)
    :ok
  end

  defp log_in_admin(%{conn: conn}) do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, admin)}
  end

  # The agent's reported system_info becomes the server's metadata, which is
  # where the dashboard reads the agent version from.
  defp connect_agent(server_id, system_info) do
    AgentConnectionManager.agent_connected(%{
      server_id: server_id,
      node: :a@h,
      connected_at: DateTime.utc_now(),
      applications: [],
      system_info: system_info
    })

    :sys.get_state(AgentConnectionManager)
  end

  describe "as an admin" do
    setup :log_in_admin

    test "renders the instance summary, audit log, and placeholders", %{conn: conn} do
      audit_event_fixture(%{
        type: "user_created",
        subject_type: :user,
        subject_id: Ecto.UUID.generate(),
        payload: %{"email" => "x@example.com"}
      })

      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Settings"
      assert html =~ "API version"
      assert html =~ "standalone"
      assert html =~ "0 of 0 hosts connected"
      assert html =~ "Audit log"
      assert html =~ "user created"
      assert html =~ "Notifications"
      assert html =~ "Danger zone"
    end

    test "summarizes mode and a mixed fleet agent version", %{conn: conn} do
      s1 = server_fixture(%{name: "s1"})
      s2 = server_fixture(%{name: "s2"})
      connect_agent(s1.id, %{"agent_version" => "1.0.0"})
      connect_agent(s2.id, %{"agent_version" => "2.0.0"})

      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "multi-node"
      assert html =~ "mixed"
      assert html =~ "2 of 2 hosts connected"
    end

    test "shows a single agent version when the fleet agrees", %{conn: conn} do
      s1 = server_fixture(%{name: "s1"})
      connect_agent(s1.id, %{"agent_version" => "1.0.0"})

      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "v1.0.0"
      assert html =~ "standalone"
    end

    test "filters the audit log by each preset", %{conn: conn} do
      audit_event_fixture(%{type: "application_created", subject_type: :application})
      audit_event_fixture(%{type: "login_succeeded"})

      {:ok, lv, _html} = live(conn, ~p"/settings")

      for preset <- ~w(applications servers users auth all) do
        assert lv |> element("button[phx-value-preset=#{preset}]") |> render_click() =~
                 "Audit log"
      end
    end

    test "expands and collapses an audit event", %{conn: conn} do
      event =
        audit_event_fixture(%{
          type: "application_created",
          subject_type: :application,
          subject_id: Ecto.UUID.generate(),
          payload: %{"name" => "api"}
        })

      {:ok, lv, _html} = live(conn, ~p"/settings")

      assert lv |> element(~s{button[phx-value-id="#{event.id}"]}) |> render_click() =~ "▾"
      refute lv |> element(~s{button[phx-value-id="#{event.id}"]}) |> render_click() =~ "▾"
    end
  end

  describe "as a viewer" do
    setup :register_and_log_in_user

    test "sees the instance summary but not the audit log", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings")

      assert html =~ "Settings"
      assert html =~ "Instance"
      refute html =~ "Audit log"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/settings")
      assert path == ~p"/users/log-in"
    end
  end
end
