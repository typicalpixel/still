defmodule Still.FleetTest do
  use Still.DataCase, async: false

  alias Still.Accounts.Scope
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Fleet
  alias Still.Fleet.Server

  import Still.AccountsFixtures
  import Still.FleetFixtures

  describe "list_servers/0" do
    test "returns an empty list when no servers exist" do
      assert [] == Fleet.list_servers()
    end

    test "returns all servers, ordered by name" do
      _b = server_fixture(%{name: "bravo"})
      _a = server_fixture(%{name: "alpha"})
      _c = server_fixture(%{name: "charlie"})

      names = Fleet.list_servers() |> Enum.map(& &1.name)
      assert names == ["alpha", "bravo", "charlie"]
    end
  end

  describe "get_server!/1" do
    test "returns the server when it exists" do
      server = server_fixture()
      assert %Server{id: id} = Fleet.get_server!(server.id)
      assert id == server.id
    end

    test "raises Ecto.NoResultsError when the server does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Fleet.get_server!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_server/1" do
    test "returns the server when it exists" do
      server = server_fixture()
      assert %Server{id: id} = Fleet.get_server(server.id)
      assert id == server.id
    end

    test "returns nil when the server does not exist" do
      assert is_nil(Fleet.get_server(Ecto.UUID.generate()))
    end
  end

  describe "ensure_server/1" do
    test "inserts a new server with the supplied id" do
      id = Ecto.UUID.generate()

      assert {:ok, %Server{id: ^id, name: "ctrl", host: "10.0.0.1", roles: ["controller"]}} =
               Fleet.ensure_server(Actor.system(), %{
                 id: id,
                 name: "ctrl",
                 host: "10.0.0.1",
                 roles: ["controller"]
               })
    end

    test "returns the existing server unchanged on re-run" do
      id = Ecto.UUID.generate()

      {:ok, first} =
        Fleet.ensure_server(Actor.system(), %{
          id: id,
          name: "ctrl",
          host: "10.0.0.1",
          roles: ["controller"]
        })

      assert {:ok, same} =
               Fleet.ensure_server(Actor.system(), %{
                 id: id,
                 name: "renamed",
                 host: "10.0.0.2",
                 roles: ["application"]
               })

      assert same.id == first.id
      assert same.name == "ctrl"
      assert same.host == "10.0.0.1"
      assert same.roles == ["controller"]
    end

    test "returns an error changeset for invalid attrs on first insert" do
      assert {:error, changeset} =
               Fleet.ensure_server(Actor.system(), %{id: Ecto.UUID.generate()})

      assert %{name: _, host: _, roles: _} = errors_on(changeset)
    end
  end

  describe "record_agent_announcement/3" do
    test "persists metadata and stamps last_seen_at" do
      server = server_fixture()
      metadata = %{hostname: "bm-fra-01", cpu_count: 8, memory_mb: 32_000}
      now = DateTime.utc_now()

      assert :ok = Fleet.record_agent_announcement(server.id, metadata, now)

      reloaded = Fleet.get_server!(server.id)
      # Map comes back from SQLite with stringified keys — compare accordingly.
      assert reloaded.metadata["hostname"] == "bm-fra-01"
      assert reloaded.metadata["cpu_count"] == 8
      assert reloaded.metadata["memory_mb"] == 32_000
      assert DateTime.compare(reloaded.last_seen_at, now) == :eq
    end

    test "is a no-op when the server id is unknown" do
      assert :ok =
               Fleet.record_agent_announcement(
                 Ecto.UUID.generate(),
                 %{hostname: "stray"},
                 DateTime.utc_now()
               )
    end

    test "overwrites prior metadata on re-announcement" do
      server = server_fixture()
      t1 = DateTime.utc_now()

      :ok = Fleet.record_agent_announcement(server.id, %{cpu_count: 4}, t1)
      :ok = Fleet.record_agent_announcement(server.id, %{cpu_count: 16}, t1)

      reloaded = Fleet.get_server!(server.id)
      assert reloaded.metadata["cpu_count"] == 16
    end
  end

  describe "create_server/1" do
    test "persists a server with valid attributes" do
      assert {:ok, %Server{} = server} =
               Fleet.create_server(Actor.system(), %{
                 name: "app-1",
                 host: "10.0.0.5",
                 roles: ["application"]
               })

      assert server.id
      assert server.name == "app-1"
      assert server.host == "10.0.0.5"
      assert server.roles == ["application"]
      assert server.metadata == %{}
      assert is_nil(server.last_seen_at)
    end

    test "returns an error changeset for invalid attributes" do
      assert {:error, changeset} = Fleet.create_server(Actor.system(), %{})
      assert %{name: _, host: _, roles: _} = errors_on(changeset)
    end

    test "rejects a duplicate name" do
      _existing = server_fixture(%{name: "duplicated"})

      assert {:error, changeset} =
               Fleet.create_server(Actor.system(), %{
                 name: "duplicated",
                 host: "10.99.99.99",
                 roles: ["application"]
               })

      assert "has already been taken" in errors_on(changeset).name
    end

    test "rejects a duplicate host" do
      _existing = server_fixture(%{host: "10.0.0.99"})

      assert {:error, changeset} =
               Fleet.create_server(Actor.system(), %{
                 name: "different-name",
                 host: "10.0.0.99",
                 roles: ["application"]
               })

      assert "has already been taken" in errors_on(changeset).host
    end
  end

  describe "update_server/2" do
    test "updates the user-editable fields" do
      server = server_fixture(%{name: "old", roles: ["application"]})

      assert {:ok, updated} =
               Fleet.update_server(Actor.system(), server, %{
                 name: "new",
                 roles: ["application", "ingress"]
               })

      assert updated.name == "new"
      assert updated.roles == ["application", "ingress"]
    end

    test "ignores attempts to set status, metadata, or last_seen_at" do
      server = server_fixture()
      now = DateTime.utc_now()

      {:ok, updated} =
        Fleet.update_server(Actor.system(), server, %{
          name: "renamed",
          metadata: %{"os" => "Debian"},
          last_seen_at: now
        })

      assert updated.name == "renamed"
      assert updated.metadata == %{}
      assert is_nil(updated.last_seen_at)
    end

    test "returns an error changeset for invalid attributes" do
      server = server_fixture()
      assert {:error, changeset} = Fleet.update_server(Actor.system(), server, %{name: ""})
      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "delete_server/1" do
    test "removes the row" do
      server = server_fixture()

      assert {:ok, %Server{}} = Fleet.delete_server(Actor.system(), server)
      assert_raise Ecto.NoResultsError, fn -> Fleet.get_server!(server.id) end
    end
  end

  describe "audit trail" do
    setup do
      user = user_fixture(%{email: "ops@example.com"})
      actor = Actor.from_scope(Scope.for_user(user))
      %{actor: actor}
    end

    test "create_server records :server_created with the new row's snapshot",
         %{actor: actor} do
      {:ok, server} =
        Fleet.create_server(actor, %{
          name: "audit-edge",
          host: "audit-edge.test",
          roles: ["application"]
        })

      assert [event] = Audit.list(type: :server_created)
      assert event.subject_type == "server"
      assert event.subject_id == server.id
      assert event.actor_label == "ops@example.com"
      assert event.after["name"] == "audit-edge"
      assert event.before == nil
    end

    test "update_server records both before and after", %{actor: actor} do
      server = server_fixture(%{name: "before-rename"})

      {:ok, _} = Fleet.update_server(actor, server, %{name: "after-rename"})

      assert [event] = Audit.list(type: :server_updated)
      assert event.before["name"] == "before-rename"
      assert event.after["name"] == "after-rename"
    end

    test "delete_server records :server_deleted with the before-snapshot",
         %{actor: actor} do
      server = server_fixture(%{name: "departing"})

      {:ok, _} = Fleet.delete_server(actor, server)

      assert [event] = Audit.list(type: :server_deleted)
      assert event.before["name"] == "departing"
      assert event.after == nil
    end

    test "ensure_server records a :server_created event when inserting", %{actor: actor} do
      id = Ecto.UUID.generate()

      {:ok, _} =
        Fleet.ensure_server(actor, %{
          id: id,
          name: "bootstrap-edge",
          host: "bootstrap.test",
          roles: ["controller"]
        })

      assert [event] = Audit.list(type: :server_created)
      assert event.subject_id == id
    end

    test "ensure_server is silent when the server already exists", %{actor: actor} do
      server = server_fixture()
      audit_count_before = length(Audit.list(type: :server_created))

      {:ok, _} =
        Fleet.ensure_server(actor, %{
          id: server.id,
          name: "ignored",
          host: "ignored.test",
          roles: ["application"]
        })

      assert length(Audit.list(type: :server_created)) == audit_count_before
    end

    test "failed create does not write an audit row", %{actor: actor} do
      assert {:error, _} = Fleet.create_server(actor, %{})
      assert Audit.list(type: :server_created) == []
    end
  end
end
