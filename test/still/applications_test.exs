defmodule Still.ApplicationsTest do
  use Still.DataCase, async: false

  alias Still.Accounts.Scope
  alias Still.Applications
  alias Still.Applications.Application
  alias Still.Applications.ApplicationServer
  alias Still.Applications.Hook
  alias Still.Audit
  alias Still.Audit.Actor

  import Still.AccountsFixtures
  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  defp valid_elixir_release_attrs(overrides) do
    Enum.into(overrides, %{
      name: unique_app_name(),
      type: :elixir_release,
      domain: "app.example.com",
      exec_command: "bin/app start",
      min_healthy: 1,
      health_check: valid_health_check_attrs(),
      artifact_source: valid_artifact_source_attrs()
    })
  end

  defp unique_app_name, do: "app-#{System.unique_integer([:positive])}"

  defp restore_controller_domain(nil),
    do: Elixir.Application.delete_env(:still, :controller_domain)

  defp restore_controller_domain(value),
    do: Elixir.Application.put_env(:still, :controller_domain, value)

  describe "list_applications/0" do
    test "returns an empty list when no applications exist" do
      assert [] == Applications.list_applications()
    end

    test "returns all applications, ordered by name" do
      _b = application_fixture(%{name: "bravo"})
      _a = application_fixture(%{name: "alpha"})
      _c = application_fixture(%{name: "charlie"})

      names = Applications.list_applications() |> Enum.map(& &1.name)
      assert names == ["alpha", "bravo", "charlie"]
    end
  end

  describe "get_application_by_name!/1" do
    test "returns the application when it exists" do
      app = application_fixture(%{name: "fetched"})
      assert %Application{id: id} = Applications.get_application_by_name!("fetched")
      assert id == app.id
    end

    test "raises Ecto.NoResultsError when the name is unknown" do
      assert_raise Ecto.NoResultsError, fn ->
        Applications.get_application_by_name!("ghost")
      end
    end
  end

  describe "create_application/1" do
    test "persists an :elixir_release application" do
      assert {:ok, %Application{} = app} =
               Applications.create_application(Actor.system(), %{
                 name: "my-api",
                 type: :elixir_release,
                 domain: "api.example.com",
                 exec_command: "bin/my_api start",
                 min_healthy: 1,
                 health_check: valid_health_check_attrs(),
                 artifact_source: valid_artifact_source_attrs()
               })

      assert app.id
      assert app.name == "my-api"
      assert app.type == :elixir_release
      assert app.domain == "api.example.com"
      assert app.health_check.path == "/health"
      assert app.artifact_source.type == :unauthenticated_url
    end

    test "persists a :static_site application without exec_command or health_check" do
      assert {:ok, %Application{} = app} =
               Applications.create_application(Actor.system(), %{
                 name: "my-site",
                 type: :static_site,
                 domain: "site.example.com",
                 min_healthy: 1,
                 artifact_source: valid_artifact_source_attrs()
               })

      assert app.type == :static_site
      assert is_nil(app.exec_command)
      assert is_nil(app.health_check)
    end

    test "returns an error changeset for invalid attributes" do
      assert {:error, changeset} = Applications.create_application(Actor.system(), %{})
      errors = errors_on(changeset)
      assert errors[:name]
      assert errors[:type]
      assert errors[:domain]
    end

    test "rejects a duplicate name" do
      _existing = application_fixture(%{name: "duplicated"})

      assert {:error, changeset} =
               Applications.create_application(Actor.system(), %{
                 name: "duplicated",
                 type: :elixir_release,
                 domain: "other.example.com",
                 exec_command: "bin/x",
                 min_healthy: 1,
                 health_check: valid_health_check_attrs(),
                 artifact_source: valid_artifact_source_attrs()
               })

      assert "has already been taken" in errors_on(changeset).name
    end

    test "rejects a second app on the same domain with no path prefix" do
      _first = application_fixture(%{name: "first-app", domain: "shared.example.com"})

      assert {:error, changeset} =
               Applications.create_application(
                 Actor.system(),
                 valid_elixir_release_attrs(%{name: "second-app", domain: "shared.example.com"})
               )

      assert "is already used by another application with the same path prefix" in errors_on(
               changeset
             ).domain
    end

    test "rejects a second app on the same domain and same path prefix" do
      _first =
        application_fixture(%{
          name: "first-api",
          domain: "shared.example.com",
          path_prefix: "/api"
        })

      assert {:error, changeset} =
               Applications.create_application(
                 Actor.system(),
                 valid_elixir_release_attrs(%{
                   name: "second-api",
                   domain: "shared.example.com",
                   path_prefix: "/api"
                 })
               )

      assert "is already used by another application with the same path prefix" in errors_on(
               changeset
             ).domain
    end

    test "allows two apps on the same domain with different path prefixes" do
      _first =
        application_fixture(%{name: "api-app", domain: "shared.example.com", path_prefix: "/api"})

      assert {:ok, _second} =
               Applications.create_application(
                 Actor.system(),
                 valid_elixir_release_attrs(%{
                   name: "web-app",
                   domain: "shared.example.com",
                   path_prefix: "/web"
                 })
               )
    end

    test "updating an app does not collide with itself on its own domain" do
      app = application_fixture(%{name: "solo-app", domain: "solo.example.com"})

      assert {:ok, updated} =
               Applications.update_application(Actor.system(), app, %{min_healthy: 2})

      assert updated.min_healthy == 2
    end

    test "rejects an app whose domain is the controller's own domain" do
      original = Elixir.Application.get_env(:still, :controller_domain)
      Elixir.Application.put_env(:still, :controller_domain, "still.example.com")
      on_exit(fn -> restore_controller_domain(original) end)

      # No path prefix — the controller route owns the whole host, so even a
      # bare app on that domain is shadowed.
      assert {:error, changeset} =
               Applications.create_application(
                 Actor.system(),
                 valid_elixir_release_attrs(%{
                   name: "controller-collision",
                   domain: "still.example.com",
                   path_prefix: nil
                 })
               )

      assert "is the controller's own domain — Still serves the dashboard and API there" in errors_on(
               changeset
             ).domain
    end

    test "matches the controller domain case-insensitively" do
      original = Elixir.Application.get_env(:still, :controller_domain)
      Elixir.Application.put_env(:still, :controller_domain, "still.example.com")
      on_exit(fn -> restore_controller_domain(original) end)

      assert {:error, changeset} =
               Applications.create_application(
                 Actor.system(),
                 valid_elixir_release_attrs(%{
                   name: "case-collision",
                   domain: "STILL.EXAMPLE.COM"
                 })
               )

      assert errors_on(changeset).domain != []
    end

    test "allows a distinct app domain even with an /api path prefix" do
      original = Elixir.Application.get_env(:still, :controller_domain)
      Elixir.Application.put_env(:still, :controller_domain, "still.example.com")
      on_exit(fn -> restore_controller_domain(original) end)

      assert {:ok, %Application{} = app} =
               Applications.create_application(
                 Actor.system(),
                 valid_elixir_release_attrs(%{
                   name: "api-prefixed",
                   domain: "app.example.com",
                   path_prefix: "/api"
                 })
               )

      assert app.path_prefix == "/api"
    end

    test "does not restrict any domain when no controller domain is configured" do
      original = Elixir.Application.get_env(:still, :controller_domain)
      Elixir.Application.delete_env(:still, :controller_domain)
      on_exit(fn -> restore_controller_domain(original) end)

      assert {:ok, %Application{}} =
               Applications.create_application(
                 Actor.system(),
                 valid_elixir_release_attrs(%{
                   name: "no-controller",
                   domain: "anything.example.com"
                 })
               )
    end

    test "treats an empty controller domain as unset (no restriction)" do
      original = Elixir.Application.get_env(:still, :controller_domain)
      Elixir.Application.put_env(:still, :controller_domain, "")
      on_exit(fn -> restore_controller_domain(original) end)

      assert {:ok, %Application{}} =
               Applications.create_application(
                 Actor.system(),
                 valid_elixir_release_attrs(%{name: "empty-domain", domain: "still.example.com"})
               )
    end

    test "ignores a non-string controller domain config" do
      original = Elixir.Application.get_env(:still, :controller_domain)
      Elixir.Application.put_env(:still, :controller_domain, :invalid)
      on_exit(fn -> restore_controller_domain(original) end)

      assert {:ok, %Application{}} =
               Applications.create_application(
                 Actor.system(),
                 valid_elixir_release_attrs(%{
                   name: "non-string-domain",
                   domain: "still.example.com"
                 })
               )
    end
  end

  describe "update_application/2" do
    test "updates the mutable fields" do
      app = application_fixture(%{name: "before"})

      assert {:ok, updated} =
               Applications.update_application(Actor.system(), app, %{
                 domain: "after.example.com",
                 min_healthy: 3
               })

      assert updated.domain == "after.example.com"
      assert updated.min_healthy == 3
      assert updated.name == "before"
    end

    test "toggles maintenance mode and stores the message" do
      app = application_fixture(%{name: "maint"})

      assert {:ok, updated} =
               Applications.update_application(Actor.system(), app, %{
                 maintenance: true,
                 maintenance_message: "Back at 5pm UTC"
               })

      assert updated.maintenance == true
      assert updated.maintenance_message == "Back at 5pm UTC"
    end

    test "rejects a maintenance message longer than 500 characters" do
      app = application_fixture(%{name: "maint-long"})

      assert {:error, changeset} =
               Applications.update_application(Actor.system(), app, %{
                 maintenance: true,
                 maintenance_message: String.duplicate("x", 501)
               })

      assert "should be at most 500 character(s)" in errors_on(changeset).maintenance_message
    end

    test "ignores attempts to change name and type" do
      app = application_fixture(%{name: "stable"})

      assert {:ok, updated} =
               Applications.update_application(Actor.system(), app, %{
                 name: "renamed",
                 type: :static_site
               })

      assert updated.name == "stable"
      assert updated.type == app.type
    end

    test "returns an error changeset when updates are invalid" do
      app = application_fixture()

      assert {:error, changeset} =
               Applications.update_application(Actor.system(), app, %{min_healthy: 0})

      assert "must be greater than or equal to 1" in errors_on(changeset).min_healthy
    end

    test "rejects updates that move an app onto the controller's own domain" do
      original = Elixir.Application.get_env(:still, :controller_domain)
      Elixir.Application.put_env(:still, :controller_domain, "still.example.com")
      on_exit(fn -> restore_controller_domain(original) end)

      app = application_fixture(%{domain: "app.example.com"})

      assert {:error, changeset} =
               Applications.update_application(Actor.system(), app, %{domain: "still.example.com"})

      assert "is the controller's own domain — Still serves the dashboard and API there" in errors_on(
               changeset
             ).domain
    end
  end

  describe "delete_application/1" do
    test "removes the row" do
      app = application_fixture()

      assert {:ok, %Application{}} = Applications.delete_application(Actor.system(), app)

      assert_raise Ecto.NoResultsError, fn ->
        Applications.get_application_by_name!(app.name)
      end
    end
  end

  describe "assign_server/3 — explicit ports" do
    test "persists the assignment with the given ports" do
      app = application_fixture()
      server = server_fixture()

      assert {:ok, %ApplicationServer{} = assignment} =
               Applications.assign_server(Actor.system(), app, server, %{
                 port_blue: 25_000,
                 port_green: 25_001
               })

      assert assignment.application_id == app.id
      assert assignment.server_id == server.id
      assert assignment.port_blue == 25_000
      assert assignment.port_green == 25_001
      assert is_nil(assignment.desired_version)
    end

    test "rejects manual ports that duplicate an existing port on the same server" do
      app1 = application_fixture()
      app2 = application_fixture()
      server = server_fixture()

      {:ok, _} =
        Applications.assign_server(Actor.system(), app1, server, %{
          port_blue: 25_000,
          port_green: 25_001
        })

      assert {:error, :port_in_use} =
               Applications.assign_server(Actor.system(), app2, server, %{
                 port_blue: 25_000,
                 port_green: 25_002
               })
    end

    test "rejects manual ports that collide cross-column with another assignment" do
      app1 = application_fixture()
      app2 = application_fixture()
      server = server_fixture()

      {:ok, _} =
        Applications.assign_server(Actor.system(), app1, server, %{
          port_blue: 25_000,
          port_green: 25_001
        })

      # app2's blue equals app1's green — the per-column unique indexes miss
      # this, so without the cross-column guard two processes would share a port.
      assert {:error, :port_in_use} =
               Applications.assign_server(Actor.system(), app2, server, %{
                 port_blue: 25_001,
                 port_green: 25_002
               })
    end

    test "returns a changeset error when port_blue and port_green are equal" do
      app = application_fixture()
      server = server_fixture()

      assert {:error, changeset} =
               Applications.assign_server(Actor.system(), app, server, %{
                 port_blue: 25_000,
                 port_green: 25_000
               })

      assert "must differ from port_blue" in errors_on(changeset).port_green
    end
  end

  describe "assign_server/3 — auto-assigned ports" do
    test "picks the first available pair from the configured range" do
      app = application_fixture()
      server = server_fixture()

      assert {:ok, assignment} = Applications.assign_server(Actor.system(), app, server)
      assert assignment.port_blue == 20_000
      assert assignment.port_green == 20_001
    end

    test "skips taken pairs and uses the next free one" do
      server = server_fixture()
      app1 = application_fixture()
      app2 = application_fixture()
      app3 = application_fixture()

      {:ok, a1} = Applications.assign_server(Actor.system(), app1, server)
      {:ok, a2} = Applications.assign_server(Actor.system(), app2, server)
      {:ok, a3} = Applications.assign_server(Actor.system(), app3, server)

      assert {a1.port_blue, a1.port_green} == {20_000, 20_001}
      assert {a2.port_blue, a2.port_green} == {20_002, 20_003}
      assert {a3.port_blue, a3.port_green} == {20_004, 20_005}
    end

    test "auto-assignment is per-server (different servers reuse the same low pair)" do
      app1 = application_fixture()
      app2 = application_fixture()
      server1 = server_fixture()
      server2 = server_fixture()

      {:ok, a1} = Applications.assign_server(Actor.system(), app1, server1)
      {:ok, a2} = Applications.assign_server(Actor.system(), app2, server2)

      assert a1.port_blue == 20_000
      assert a2.port_blue == 20_000
    end

    test "returns :no_available_ports when the configured range is exhausted" do
      original = Elixir.Application.get_env(:still, :auto_port_range)
      Elixir.Application.put_env(:still, :auto_port_range, 30_000..30_001//2)
      on_exit(fn -> Elixir.Application.put_env(:still, :auto_port_range, original) end)

      server = server_fixture()
      app1 = application_fixture()
      app2 = application_fixture()

      assert {:ok, _} = Applications.assign_server(Actor.system(), app1, server)

      assert {:error, :no_available_ports} =
               Applications.assign_server(Actor.system(), app2, server)
    end
  end

  describe "assign_server/3 — duplicate assignments" do
    test "rejects assigning the same application to the same server twice" do
      app = application_fixture()
      server = server_fixture()

      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      assert {:error, changeset} = Applications.assign_server(Actor.system(), app, server)
      assert "has already been taken" in errors_on(changeset).application_id
    end
  end

  describe "list_application_servers/1" do
    test "returns only the assignments for the given application" do
      app = application_fixture()
      other = application_fixture()
      server1 = server_fixture()
      server2 = server_fixture()
      _other_assignment = application_server_fixture(other, server1)

      {:ok, a1} = Applications.assign_server(Actor.system(), app, server1)
      {:ok, a2} = Applications.assign_server(Actor.system(), app, server2)

      ids = app |> Applications.list_application_servers() |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([a1.id, a2.id])
    end

    test "returns an empty list when the application has no servers" do
      app = application_fixture()
      assert [] == Applications.list_application_servers(app)
    end
  end

  describe "get_application_server!/1" do
    test "returns the assignment when it exists" do
      app = application_fixture()
      server = server_fixture()
      assignment = application_server_fixture(app, server)

      assert %ApplicationServer{id: id} = Applications.get_application_server!(assignment.id)
      assert id == assignment.id
    end

    test "raises Ecto.NoResultsError when the id is unknown" do
      assert_raise Ecto.NoResultsError, fn ->
        Applications.get_application_server!(Ecto.UUID.generate())
      end
    end
  end

  describe "unassign_server/1" do
    test "removes the assignment row" do
      app = application_fixture()
      server = server_fixture()
      assignment = application_server_fixture(app, server)

      assert {:ok, %ApplicationServer{}} =
               Applications.unassign_server(Actor.system(), assignment)

      assert_raise Ecto.NoResultsError, fn ->
        Applications.get_application_server!(assignment.id)
      end
    end
  end

  describe "create_hook/2" do
    test "persists a hook scoped to the given application" do
      app = application_fixture()

      assert {:ok, %Hook{} = hook} =
               Applications.create_hook(Actor.system(), app, %{
                 event: :pre_deploy,
                 script: "#!/bin/bash\necho hi",
                 timeout_ms: 30_000
               })

      assert hook.application_id == app.id
      assert hook.event == :pre_deploy
      assert hook.script == "#!/bin/bash\necho hi"
      assert hook.timeout_ms == 30_000
    end

    test "ignores any application_id passed in attrs and uses the parent's id" do
      app = application_fixture()
      other = application_fixture()

      {:ok, hook} =
        Applications.create_hook(Actor.system(), app, %{
          event: :pre_deploy,
          script: "echo",
          timeout_ms: 1_000,
          application_id: other.id
        })

      assert hook.application_id == app.id
    end

    test "returns an error changeset for invalid attributes" do
      app = application_fixture()
      assert {:error, changeset} = Applications.create_hook(Actor.system(), app, %{})
      errors = errors_on(changeset)
      assert errors[:event]
      assert errors[:script]
    end

    test "rejects a duplicate (application, event) pair" do
      app = application_fixture()
      _existing = hook_fixture(app, %{event: :pre_deploy})

      assert {:error, changeset} =
               Applications.create_hook(Actor.system(), app, %{
                 event: :pre_deploy,
                 script: "echo",
                 timeout_ms: 1_000
               })

      assert "has already been taken" in errors_on(changeset).application_id
    end
  end

  describe "list_hooks_for/1" do
    test "returns only the hooks for the given application, ordered by event" do
      app = application_fixture()
      other = application_fixture()
      _other_hook = hook_fixture(other, %{event: :pre_deploy})

      hook_fixture(app, %{event: :post_deploy})
      hook_fixture(app, %{event: :pre_deploy})
      hook_fixture(app, %{event: :post_rollback})

      events = app |> Applications.list_hooks_for() |> Enum.map(& &1.event)
      assert events == Enum.sort(events)
    end

    test "returns an empty list when the application has no hooks" do
      app = application_fixture()
      assert [] == Applications.list_hooks_for(app)
    end
  end

  describe "get_hook!/1" do
    test "returns the hook when it exists" do
      app = application_fixture()
      hook = hook_fixture(app)

      assert %Hook{id: id} = Applications.get_hook!(hook.id)
      assert id == hook.id
    end

    test "raises Ecto.NoResultsError when the id is unknown" do
      assert_raise Ecto.NoResultsError, fn ->
        Applications.get_hook!(Ecto.UUID.generate())
      end
    end
  end

  describe "update_hook/2" do
    test "updates script and timeout_ms" do
      app = application_fixture()
      hook = hook_fixture(app, %{script: "old", timeout_ms: 1_000})

      assert {:ok, updated} =
               Applications.update_hook(Actor.system(), hook, %{script: "new", timeout_ms: 2_000})

      assert updated.script == "new"
      assert updated.timeout_ms == 2_000
    end

    test "ignores attempts to change the event" do
      app = application_fixture()
      hook = hook_fixture(app, %{event: :pre_deploy})

      assert {:ok, updated} =
               Applications.update_hook(Actor.system(), hook, %{
                 script: "new",
                 timeout_ms: 1_000,
                 event: :post_rollback
               })

      assert updated.event == :pre_deploy
    end

    test "returns an error changeset for invalid attributes" do
      app = application_fixture()
      hook = hook_fixture(app)

      assert {:error, changeset} = Applications.update_hook(Actor.system(), hook, %{script: ""})
      assert "can't be blank" in errors_on(changeset).script
    end
  end

  describe "delete_hook/1" do
    test "removes the row" do
      app = application_fixture()
      hook = hook_fixture(app)

      assert {:ok, %Hook{}} = Applications.delete_hook(Actor.system(), hook)

      assert_raise Ecto.NoResultsError, fn ->
        Applications.get_hook!(hook.id)
      end
    end
  end

  describe "list_all_assignments/0" do
    test "returns assignments with application names and desired versions" do
      app = application_fixture()
      server = server_fixture()
      {:ok, as} = Applications.assign_server(Actor.system(), app, server)
      {:ok, _} = Applications.set_desired_version(as, "1.0.0")

      [entry] = Applications.list_all_assignments()
      assert entry.application_name == app.name
      assert entry.server_id == server.id
      assert entry.desired_version == "1.0.0"
    end

    test "returns an empty list when no assignments exist" do
      assert [] == Applications.list_all_assignments()
    end
  end

  describe "list_routes/0" do
    test "returns an empty list when no applications exist" do
      assert [] == Applications.list_routes()
    end

    test "omits applications that have no server assignments" do
      application_fixture(%{name: "unassigned"})
      assert [] == Applications.list_routes()
    end

    test "returns one entry per assigned application with its server rows" do
      app = application_fixture(%{name: "api"})
      server_a = server_fixture(%{name: "agent-a", host: "10.0.0.3"})
      server_b = server_fixture(%{name: "agent-b", host: "10.0.0.4"})

      {:ok, _} = Applications.assign_server(Actor.system(), app, server_a)
      {:ok, _} = Applications.assign_server(Actor.system(), app, server_b)

      [entry] = Applications.list_routes()
      assert entry.application.name == "api"

      hosts = Enum.map(entry.servers, & &1.host) |> Enum.sort()
      assert hosts == ["10.0.0.3", "10.0.0.4"]
    end

    test "groups distinct applications into separate entries and sorts by app name" do
      app_beta = application_fixture(%{name: "beta"})
      app_alpha = application_fixture(%{name: "alpha"})
      server = server_fixture()

      {:ok, _} = Applications.assign_server(Actor.system(), app_beta, server)
      {:ok, _} = Applications.assign_server(Actor.system(), app_alpha, server)

      entries = Applications.list_routes()
      assert Enum.map(entries, & &1.application.name) == ["alpha", "beta"]
    end

    test "sorts server rows within an entry by server name" do
      app = application_fixture()
      server_z = server_fixture(%{name: "z-agent"})
      server_a = server_fixture(%{name: "a-agent"})

      {:ok, _} = Applications.assign_server(Actor.system(), app, server_z)
      {:ok, _} = Applications.assign_server(Actor.system(), app, server_a)

      [entry] = Applications.list_routes()
      assert Enum.map(entry.servers, & &1.name) == ["a-agent", "z-agent"]
    end
  end

  describe "set_desired_version/2" do
    test "updates the desired_version on an application server" do
      app = application_fixture()
      server = server_fixture()
      {:ok, as} = Applications.assign_server(Actor.system(), app, server)
      assert is_nil(as.desired_version)

      {:ok, updated} = Applications.set_desired_version(as, "1.0.0")
      assert updated.desired_version == "1.0.0"
    end
  end

  describe "set_desired_version_for_all/2" do
    test "stamps every assignment for the application and returns the count" do
      app = application_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server_fixture())
      {:ok, _} = Applications.assign_server(Actor.system(), app, server_fixture())

      assert 2 = Applications.set_desired_version_for_all(app, "9.9.9")

      versions =
        app |> Applications.list_application_servers() |> Enum.map(& &1.desired_version)

      assert versions == ["9.9.9", "9.9.9"]
    end
  end

  describe "audit trail" do
    setup do
      user = user_fixture(%{email: "auditor@example.com"})
      actor = Actor.from_scope(Scope.for_user(user))
      %{actor: actor, user: user}
    end

    test "create_application records an :application_created event with after-snapshot",
         %{actor: actor} do
      {:ok, app} =
        Applications.create_application(actor, %{
          name: "audited",
          type: :elixir_release,
          domain: "audited.example.com",
          exec_command: "bin/audited start",
          min_healthy: 1,
          health_check: valid_health_check_attrs(),
          artifact_source: valid_artifact_source_attrs()
        })

      assert [event] = Audit.list(type: :application_created)
      assert event.subject_type == "application"
      assert event.subject_id == app.id
      assert event.actor_label == "auditor@example.com"
      assert event.payload["application_name"] == "audited"
      assert event.before == nil
      assert event.after["name"] == "audited"
    end

    test "update_application captures both before and after snapshots", %{actor: actor} do
      app = application_fixture(%{domain: "before.example.com"})

      {:ok, _} = Applications.update_application(actor, app, %{domain: "after.example.com"})

      assert [event] = Audit.list(type: :application_updated)
      assert event.before["domain"] == "before.example.com"
      assert event.after["domain"] == "after.example.com"
    end

    test "delete_application captures the before-snapshot and leaves after nil",
         %{actor: actor} do
      app = application_fixture(%{name: "doomed"})

      {:ok, _} = Applications.delete_application(actor, app)

      assert [event] = Audit.list(type: :application_deleted)
      assert event.before["name"] == "doomed"
      assert event.after == nil
    end

    test "assign_server records port pair and both names in the payload", %{actor: actor} do
      app = application_fixture(%{name: "assigned"})
      server = server_fixture(%{name: "edge-7"})

      {:ok, assignment} =
        Applications.assign_server(actor, app, server, %{port_blue: 30_000, port_green: 30_001})

      assert [event] = Audit.list(type: :application_server_assigned)
      assert event.subject_id == assignment.id

      assert event.payload["application_name"] == "assigned"
      assert event.payload["server_name"] == "edge-7"
      assert event.payload["port_blue"] == 30_000
      assert event.payload["port_green"] == 30_001
    end

    test "unassign_server records the assignment's pre-delete snapshot", %{actor: actor} do
      app = application_fixture(%{name: "unbinding"})
      server = server_fixture(%{name: "edge-3"})
      assignment = application_server_fixture(app, server)

      {:ok, _} = Applications.unassign_server(actor, assignment)

      assert [event] = Audit.list(type: :application_server_unassigned)
      assert event.payload["application_name"] == "unbinding"
      assert event.payload["server_name"] == "edge-3"
      assert event.before["port_blue"] == assignment.port_blue
    end

    test "failed mutation does not create an audit row", %{actor: actor} do
      assert {:error, %Ecto.Changeset{}} = Applications.create_application(actor, %{})
      assert Audit.list(type: :application_created) == []
    end
  end
end
