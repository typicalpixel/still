defmodule StillWeb.EventsLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.FleetFixtures

  alias Still.EventLog

  defp record(event) do
    EventLog.record(Map.put_new(event, :at, DateTime.utc_now()))
    # Drain the log's mailbox so the write lands in ETS (and is rebroadcast)
    # before we read or assert.
    :sys.get_state(EventLog)
  end

  describe "activity" do
    setup :register_and_log_in_user

    setup do
      # Create the server before the log starts so its audit event isn't
      # captured; the activity stream begins empty.
      server = server_fixture(%{name: "web-1"})
      start_supervised!(EventLog)
      %{server: server}
    end

    test "lists derived activity rows and filters by type", %{conn: conn, server: server} do
      record(%{
        id: "d1",
        type: :deployment_updated,
        payload: %{application_name: "api", status: :completed, deployment_id: "dep-123"}
      })

      record(%{
        id: "h1",
        type: :health_transition,
        payload: %{application_name: "api", from: :healthy, to: :degraded}
      })

      record(%{id: "s1", type: :server_connected, payload: %{server_id: server.id}})

      {:ok, _lv, html} = live(conn, ~p"/events")

      assert html =~ "Activity"
      assert html =~ "api deploy completed"
      assert html =~ "api health healthy → degraded"
      assert html =~ "web-1 connected"
      assert html =~ "showing 3 of 3"

      {:ok, _lv, html} = live(conn, ~p"/events?type=deployment")
      assert html =~ "api deploy completed"
      refute html =~ "web-1 connected"

      {:ok, _lv, html} = live(conn, ~p"/events?type=health")
      assert html =~ "api health healthy → degraded"
      refute html =~ "api deploy completed"

      {:ok, _lv, html} = live(conn, ~p"/events?type=server")
      assert html =~ "web-1 connected"
      refute html =~ "api deploy completed"
    end

    test "counts but doesn't show per-step deployment pings", %{conn: conn} do
      record(%{
        id: "step1",
        type: :deployment_updated,
        payload: %{server_id: "s1", step_status: :completed, deployment_id: "dep-1"}
      })

      {:ok, _lv, html} = live(conn, ~p"/events")

      assert html =~ "showing 0 of 1"
      assert html =~ "No events match this filter."
    end

    test "prepends events as they arrive live", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/events")

      record(%{
        id: "live1",
        type: :health_transition,
        payload: %{application_name: "api", from: :degraded, to: :healthy}
      })

      assert render(lv) =~ "api health degraded → healthy"
    end

    test "shows an empty notice when there are no events", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/events")
      assert html =~ "No events match this filter."
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/events")
      assert path == ~p"/users/log-in"
    end
  end
end
