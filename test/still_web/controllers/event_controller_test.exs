defmodule StillWeb.EventControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.Audit.Actor
  alias Still.EventLog

  import Still.AccountsFixtures
  import Still.EventFixtures

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, api_key} =
      Accounts.create_api_key(Actor.system(), user, %{name: "events", permissions: ["read"]})

    conn = put_req_header(conn, "authorization", "Bearer #{api_key.raw_key}")

    start_supervised!(EventLog)

    %{conn: conn}
  end

  defp wait_for_processing, do: :sys.get_state(EventLog)

  describe "GET /api/events" do
    test "returns an empty list when nothing has been recorded", %{conn: conn} do
      body = conn |> get("/api/events") |> json_response(200)
      assert body["data"] == []
    end

    test "returns events newest first", %{conn: conn} do
      now = DateTime.utc_now()

      EventLog.record(
        event_fixture(
          type: :server_connected,
          payload: %{server_id: "older"},
          at: DateTime.add(now, -10, :second)
        )
      )

      EventLog.record(
        event_fixture(type: :server_connected, payload: %{server_id: "newer"}, at: now)
      )

      wait_for_processing()

      body = conn |> get("/api/events") |> json_response(200)

      assert [
               %{"payload" => %{"server_id" => "newer"}},
               %{"payload" => %{"server_id" => "older"}}
             ] = body["data"]
    end

    test "filters by type", %{conn: conn} do
      EventLog.record(event_fixture(type: :server_connected, payload: %{server_id: "a"}))
      EventLog.record(event_fixture(type: :health_transition, payload: %{server_id: "b"}))
      wait_for_processing()

      body = conn |> get("/api/events?type=health_transition") |> json_response(200)

      assert [%{"type" => "health_transition"}] = body["data"]
    end

    test "respects the limit query param", %{conn: conn} do
      for i <- 1..5 do
        EventLog.record(event_fixture(payload: %{server_id: "srv-#{i}"}))
      end

      wait_for_processing()

      body = conn |> get("/api/events?limit=2") |> json_response(200)
      assert length(body["data"]) == 2
    end
  end

  describe "authorization" do
    test "requires authentication" do
      conn = build_conn() |> get("/api/events")
      assert conn.status == 401
    end
  end
end
