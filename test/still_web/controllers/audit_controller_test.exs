defmodule StillWeb.AuditControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.Audit
  alias Still.Audit.Actor

  import Still.AccountsFixtures
  import Still.AuditFixtures

  setup %{conn: conn} do
    admin = user_fixture(%{role: :admin})

    {:ok, admin_key} =
      Accounts.create_api_key(Actor.system(), admin, %{name: "ops", permissions: ["admin"]})

    admin_conn = put_req_header(conn, "authorization", "Bearer #{admin_key.raw_key}")

    %{conn: admin_conn, admin: admin}
  end

  describe "GET /api/audit" do
    test "returns an empty list for a type with no recorded events", %{conn: conn} do
      body = conn |> get("/api/audit?type=application_deleted") |> json_response(200)
      assert body["data"] == []
    end

    test "returns events newest first with full actor and snapshot fields", %{conn: conn} do
      now = DateTime.utc_now()

      _older =
        audit_event_fixture(
          type: :application_created,
          subject_type: :application,
          subject_id: "app-1",
          payload: %{application_name: "older"},
          after: %{name: "older"},
          inserted_at: DateTime.add(now, -10, :second)
        )

      _newer =
        audit_event_fixture(
          type: :application_deleted,
          subject_type: :application,
          subject_id: "app-2",
          payload: %{application_name: "newer"},
          before: %{name: "newer"},
          inserted_at: now
        )

      body = conn |> get("/api/audit?subject_type=application") |> json_response(200)

      assert [
               %{
                 "type" => "application_deleted",
                 "subject_type" => "application",
                 "subject_id" => "app-2",
                 "payload" => %{"application_name" => "newer"},
                 "before" => %{"name" => "newer"},
                 "after" => nil,
                 "actor" => %{"kind" => "system", "label" => "system"}
               },
               %{
                 "type" => "application_created",
                 "after" => %{"name" => "older"},
                 "before" => nil
               }
             ] = body["data"]
    end

    test "filters by type", %{conn: conn} do
      {:ok, _} = Audit.record(Actor.system(), type: :application_created)
      {:ok, _} = Audit.record(Actor.system(), type: :application_deleted)

      body = conn |> get("/api/audit?type=application_deleted") |> json_response(200)

      assert [%{"type" => "application_deleted"}] = body["data"]
    end

    test "filters by subject", %{conn: conn} do
      {:ok, _} =
        Audit.record(Actor.system(),
          type: :application_updated,
          subject_type: :application,
          subject_id: "app-1"
        )

      {:ok, _} =
        Audit.record(Actor.system(),
          type: :application_updated,
          subject_type: :application,
          subject_id: "app-2"
        )

      body =
        conn
        |> get("/api/audit?subject_type=application&subject_id=app-1")
        |> json_response(200)

      assert [%{"subject_id" => "app-1"}] = body["data"]
    end

    test "respects the limit query param", %{conn: conn} do
      for _ <- 1..5, do: Audit.record(Actor.system(), type: :application_created)

      body = conn |> get("/api/audit?limit=2") |> json_response(200)
      assert length(body["data"]) == 2
    end

    test "exposes actor IP and user-agent", %{conn: conn, admin: admin} do
      actor = %Actor{
        kind: :user,
        label: admin.email,
        user_id: admin.id,
        ip: "203.0.113.7",
        user_agent: "still/test"
      }

      {:ok, _} =
        Audit.record(actor,
          type: :application_created,
          subject_type: :application,
          subject_id: "app-x"
        )

      body = conn |> get("/api/audit?type=application_created") |> json_response(200)
      admin_email = admin.email

      assert [
               %{
                 "actor" => %{
                   "kind" => "user",
                   "label" => ^admin_email,
                   "user_id" => user_id,
                   "ip" => "203.0.113.7",
                   "user_agent" => "still/test"
                 }
               }
             ] = body["data"]

      assert user_id == admin.id
    end
  end

  describe "authorization" do
    test "requires authentication" do
      conn = build_conn() |> get("/api/audit")
      assert conn.status == 401
    end

    test "rejects non-admin scopes", %{conn: _admin_conn} do
      reader = user_fixture(%{role: :viewer})

      {:ok, key} =
        Accounts.create_api_key(Actor.system(), reader, %{name: "reader", permissions: ["read"]})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key.raw_key}")
        |> get("/api/audit")

      assert conn.status == 403
    end
  end
end
