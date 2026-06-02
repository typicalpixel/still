defmodule Still.AuditTest do
  use Still.DataCase, async: false

  alias Still.Accounts.Scope
  alias Still.Audit
  alias Still.Audit.{Actor, AuditEvent}
  alias Still.{EventLog, Events}

  import Still.AccountsFixtures
  import Still.AuditFixtures
  import Still.FleetFixtures

  setup do
    start_supervised!(EventLog)
    Events.subscribe("events:lobby")
    :ok
  end

  describe "record/2" do
    test "writes a row with the actor's identity, label, and IP" do
      user = user_fixture(%{email: "ops@example.com"})

      actor = %Actor{
        kind: :user,
        label: user.email,
        user_id: user.id,
        ip: "10.0.0.7",
        user_agent: "still/test"
      }

      assert {:ok, %AuditEvent{} = event} =
               Audit.record(actor,
                 type: :application_created,
                 subject_type: :application,
                 subject_id: "app-1",
                 payload: %{application_name: "demo"}
               )

      assert event.type == "application_created"
      assert event.subject_type == "application"
      assert event.subject_id == "app-1"
      assert event.actor_kind == :user
      assert event.actor_label == "ops@example.com"
      assert event.actor_user_id == user.id
      assert event.ip == "10.0.0.7"
      assert event.user_agent == "still/test"
    end

    test "stores before/after snapshots verbatim" do
      assert {:ok, %AuditEvent{} = event} =
               Audit.record(Actor.system(),
                 type: :application_updated,
                 subject_type: :application,
                 subject_id: "app-1",
                 before: %{domain: "old.example.com"},
                 after: %{domain: "new.example.com"}
               )

      assert event.before == %{domain: "old.example.com"}
      assert event.after == %{domain: "new.example.com"}
    end

    test "emits the event onto events:lobby with actor info merged in" do
      user = user_fixture(%{email: "user@example.com"})
      actor = Actor.from_scope(Scope.for_user(user))

      {:ok, %AuditEvent{id: id}} =
        Audit.record(actor,
          type: :application_server_unassigned,
          payload: %{application_name: "demo", server_name: "edge-01"}
        )

      assert_receive {:event_recorded,
                      %{
                        id: ^id,
                        type: :application_server_unassigned,
                        payload: %{
                          application_name: "demo",
                          server_name: "edge-01",
                          actor_kind: :user,
                          actor_label: "user@example.com"
                        }
                      }}
    end

    test "agent actor records server_id but no user/api_key ids" do
      server = server_fixture(%{name: "edge-01"})
      actor = Actor.agent(server)

      {:ok, event} = Audit.record(actor, type: :health_transition, payload: %{})

      assert event.actor_kind == :agent
      assert event.actor_label == "agent:edge-01"
      assert event.actor_server_id == server.id
      assert is_nil(event.actor_user_id)
      assert is_nil(event.actor_api_key_id)
    end

    test "rejects rows missing the type" do
      assert_raise KeyError, fn ->
        Audit.record(Actor.system(), payload: %{})
      end
    end

    test "returns {:error, changeset} when validation fails" do
      assert {:error, %Ecto.Changeset{valid?: false}} =
               Audit.record(Actor.system(), type: "")
    end

    test "accepts string subject_type and subject_id pass-through" do
      assert {:ok, event} =
               Audit.record(Actor.system(),
                 type: :application_created,
                 subject_type: "application",
                 subject_id: "app-1"
               )

      assert event.subject_type == "application"
      assert event.subject_id == "app-1"
    end
  end

  describe "list/1" do
    test "returns events newest first" do
      now = DateTime.utc_now()

      older =
        audit_event_fixture(
          type: :application_created,
          inserted_at: DateTime.add(now, -10, :second)
        )

      newer = audit_event_fixture(type: :application_updated, inserted_at: now)

      assert [%{id: bid}, %{id: aid}] = Audit.list()
      assert bid == newer.id
      assert aid == older.id
    end

    test "filters by type" do
      _a = system_record!(:application_created)
      b = system_record!(:application_deleted)

      assert [%{id: id}] = Audit.list(type: "application_deleted")
      assert id == b.id
    end

    test "filters by actor_user_id" do
      user = user_fixture()
      other = user_fixture()

      user_actor = Actor.from_scope(Scope.for_user(user))
      other_actor = Actor.from_scope(Scope.for_user(other))

      {:ok, _} = Audit.record(user_actor, type: :application_created)
      {:ok, _} = Audit.record(other_actor, type: :application_created)
      {:ok, _} = Audit.record(user_actor, type: :application_deleted)

      results = Audit.list(actor_user_id: user.id)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.actor_user_id == user.id))
    end

    test "filters by subject_type and subject_id" do
      _ = system_record!(:application_created, subject_type: :application, subject_id: "app-1")

      _ =
        audit_event_fixture(
          type: :application_updated,
          subject_type: "application",
          subject_id: "app-2"
        )

      _ = system_record!(:application_updated, subject_type: :application, subject_id: "app-1")

      results = Audit.list(subject_type: "application", subject_id: "app-1")
      assert length(results) == 2
    end

    test "filters by since (inclusive) and until (exclusive)" do
      mid = DateTime.utc_now()

      _ =
        audit_event_fixture(
          type: :application_created,
          payload: %{label: "old"},
          inserted_at: DateTime.add(mid, -10, :second)
        )

      _ =
        audit_event_fixture(
          type: :application_updated,
          payload: %{label: "new"},
          inserted_at: DateTime.add(mid, 10, :second)
        )

      newer = Audit.list(since: DateTime.to_iso8601(mid))
      assert length(newer) == 1
      assert hd(newer).payload["label"] == "new"

      older = Audit.list(until: DateTime.to_iso8601(mid))
      assert length(older) == 1
      assert hd(older).payload["label"] == "old"
    end

    test "respects the limit and clamps it to 1..500" do
      for _ <- 1..3, do: system_record!(:application_created)

      assert length(Audit.list(limit: 2)) == 2
      assert length(Audit.list(limit: 0)) == 1
      assert length(Audit.list(limit: "2")) == 2
      assert length(Audit.list(limit: "garbage")) == 3
      assert length(Audit.list(limit: :nope)) == 3
    end

    test "ignores garbage since/until values" do
      _ = system_record!(:application_created)

      assert length(Audit.list(since: "not-a-date")) == 1
      assert length(Audit.list(until: "also-not")) == 1
    end
  end

  describe "snapshot/1" do
    test "returns nil for nil" do
      assert Audit.snapshot(nil) == nil
    end

    test "passes through DateTime, Date, Time, NaiveDateTime values inside a struct" do
      user = user_fixture()
      result = Audit.snapshot(user)

      assert %DateTime{} = result.inserted_at
      assert %DateTime{} = result.updated_at
    end

    test "passes through non-Ecto structs unchanged" do
      ip = %URI{scheme: "https", host: "example.com"}
      assert Audit.snapshot(ip) == ip
    end

    test "passes through bare DateTime/Date/Time at the top level" do
      now = DateTime.utc_now()
      today = Date.utc_today()
      noon = ~T[12:00:00]
      naive = NaiveDateTime.utc_now()

      assert Audit.snapshot(now) == now
      assert Audit.snapshot(today) == today
      assert Audit.snapshot(noon) == noon
      assert Audit.snapshot(naive) == naive
    end
  end

  defp system_record!(type, opts \\ []) do
    {:ok, event} = Audit.record(Actor.system(), [{:type, type} | opts])
    event
  end
end
