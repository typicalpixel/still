defmodule StillWeb.ApplicationLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.ApplicationsFixtures
  import Still.AuditFixtures
  import Still.DeploymentsFixtures
  import Still.FleetFixtures

  alias Still.AccountsFixtures
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.CaddyMetricsScraper
  alias Still.Deployments
  alias Still.Events
  alias Still.MetricsCollector
  alias Still.Orchestrator

  setup do
    start_supervised!(AgentConnectionManager)
    start_supervised!(MetricsCollector)

    start_supervised!(
      {CaddyMetricsScraper, interval_ms: 60_000, http_getter: fn _ -> {:ok, ""} end}
    )

    :ok
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(
      Still.PubSub,
      "events:lobby",
      {:event_recorded, Map.put(event, :at, DateTime.utc_now())}
    )
  end

  describe "application detail" do
    setup :register_and_log_in_user

    test "renders summary, config, environment, and hooks sections", %{conn: conn} do
      app = application_fixture(%{name: "api", min_healthy: 1})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)
      # A second assigned-but-disconnected host (no live report).
      server2 = server_fixture(%{name: "s2"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server2)
      Applications.set_desired_version_for_all(app, "1.0.0")
      _deploy = deployment_fixture(app)

      AgentConnectionManager.agent_connected(%{
        server_id: server.id,
        node: :a@h,
        connected_at: DateTime.utc_now(),
        applications: [
          %{
            application_name: "api",
            health: :healthy,
            current_version: "1.0.0",
            active_slot: :blue
          }
        ]
      })

      :sys.get_state(AgentConnectionManager)

      {:ok, _lv, html} = live(conn, ~p"/applications/api")

      assert html =~ "api"
      assert html =~ "elixir"
      assert html =~ "1.0.0"
      assert html =~ "healthy"
      assert html =~ "Fleet"
      assert html =~ "s1"
      assert html =~ "s2"
      assert html =~ "Deploy history"
      assert html =~ "Configuration"
      assert html =~ "Environment"
      assert html =~ "Lifecycle hooks"
    end

    test "renders not-found for an unknown name", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/applications/nope")
      assert html =~ "Application not found"
    end

    test "reloads on deploy, server, and fleet events", %{conn: conn} do
      _app = application_fixture(%{name: "api"})
      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      broadcast_event(%{id: "e1", type: :deployment_updated, payload: %{application_name: "api"}})
      broadcast_event(%{id: "e2", type: :server_connected, payload: %{server_id: "s1"}})
      Events.server_connected("s1", :a@h)
      Events.server_disconnected("s1")
      Events.fleet_changed()

      assert render(lv) =~ "api"
    end
  end

  describe "admin actions" do
    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      %{conn: log_in_user(conn, admin)}
    end

    test "shows the audit history and expands an event", %{conn: conn} do
      app = application_fixture(%{name: "api"})

      event =
        audit_event_fixture(%{
          type: "application_updated",
          subject_type: :application,
          subject_id: app.id,
          payload: %{"min_healthy" => 2}
        })

      {:ok, lv, html} = live(conn, ~p"/applications/api")

      assert html =~ "Audit history"
      assert html =~ "application updated"
      assert lv |> element(~s|button[phx-value-id="#{event.id}"]|) |> render_click() =~ "▾"
    end

    test "enters maintenance with a message, shows the banner, then exits", %{conn: conn} do
      application_fixture(%{name: "api"})
      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Maintenance") |> render_click()

      html =
        lv |> form("#maintenance form", %{message: "Back at 5pm UTC"}) |> render_submit()

      assert html =~ "In maintenance"
      assert html =~ "Back at 5pm UTC"
      assert Still.Applications.get_application_by_name("api").maintenance == true

      html = lv |> element("button", "Exit maintenance") |> render_click()
      refute html =~ "In maintenance"
      assert Still.Applications.get_application_by_name("api").maintenance == false

      # Flush the LV's pending fleet_changed reload so its async DB read
      # doesn't race sandbox teardown.
      render(lv)
    end

    test "cancels the maintenance dialog without changing state", %{conn: conn} do
      application_fixture(%{name: "api"})
      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Maintenance") |> render_click()
      lv |> element("#maintenance button", "Cancel") |> render_click()

      assert Still.Applications.get_application_by_name("api").maintenance == false
    end

    test "shows an error when the maintenance message is too long", %{conn: conn} do
      application_fixture(%{name: "api"})
      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Maintenance") |> render_click()

      html =
        lv
        |> form("#maintenance form", %{message: String.duplicate("x", 501)})
        |> render_submit()

      assert html =~ "Couldn&#39;t update maintenance mode" or
               html =~ "Couldn't update maintenance mode"

      assert Still.Applications.get_application_by_name("api").maintenance == false
    end

    test "refuses to delete while servers are assigned", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Delete") |> render_click()
      html = lv |> element("#delete-app button", "Delete") |> render_click()

      assert html =~ "Unassign every server"

      refute lv |> element("#delete-app button", "Cancel") |> render_click() =~
               "Unassign every server"
    end

    test "deletes an application with no assignments", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Delete") |> render_click()

      assert {:error, {:live_redirect, %{to: "/applications"}}} =
               lv |> element("#delete-app button", "Delete") |> render_click()
    end

    test "assigns an eligible server", %{conn: conn} do
      application_fixture(%{name: "api"})
      server = server_fixture(%{name: "s1"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Assign server") |> render_click()
      html = lv |> form("#assign-server-form", %{server_id: server.id}) |> render_submit()

      assert html =~ "s1 assigned"
      # The mutation fires fleet_changed; flush the LV's async reload so it
      # doesn't run a query as the test tears down its sandbox connection.
      assert render(lv) =~ "api"
    end

    test "rejects an empty selection and a duplicate assignment", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      server = server_fixture(%{name: "s1"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Assign server") |> render_click()

      assert lv |> form("#assign-server-form", %{server_id: ""}) |> render_submit() =~
               "Pick a server."

      # Assigning out-of-band, then re-assigning the same server, trips the unique guard.
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      assert render_hook(lv, "assign_server", %{"server_id" => server.id}) =~ "assign that server"
    end

    test "surfaces a missing server selection", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Assign server") |> render_click()

      assert render_hook(lv, "assign_server", %{"server_id" => Ecto.UUID.generate()}) =~
               "Couldn"
    end

    test "opens then cancels the assign dialog", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      assert lv |> element("button", "Assign server") |> render_click() =~ "Assign a server to"

      refute lv |> element("#assign-server button", "Cancel") |> render_click() =~
               "Assign a server to"
    end

    test "unassigns a server", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      {:ok, lv, html} = live(conn, ~p"/applications/api")
      assert html =~ "s1"

      lv |> element("#fleet button", "Unassign") |> render_click()
      assert render(lv) =~ "stops receiving deploy steps"

      html = lv |> element("#unassign-server button", "Unassign") |> render_click()
      assert html =~ "s1 unassigned"
      assert html =~ "No servers assigned."
      assert render(lv) =~ "api"
    end

    test "opens then cancels the unassign dialog", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      assert lv |> element("#fleet button", "Unassign") |> render_click() =~
               "stops receiving deploy steps"

      refute lv |> element("#unassign-server button", "Cancel") |> render_click() =~
               "stops receiving deploy steps"
    end

    test "edits the configuration", %{conn: conn} do
      application_fixture(%{name: "api", domain: "old.example.com"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button[phx-click=open_config]") |> render_click()

      html =
        lv
        |> form("#edit-config-form", %{
          domain: "new.example.com",
          path_prefix: "/v1",
          min_healthy: "2",
          exec_command: "bin/app start",
          artifact_type: "unauthenticated_url",
          hc_path: "/healthz",
          hc_interval: "5000",
          hc_deadline: "3000"
        })
        |> render_submit()

      assert html =~ "Configuration saved"
      assert html =~ "new.example.com"
      assert render(lv) =~ "api"
    end

    test "saves a config without exec or health-check fields", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      html =
        render_hook(lv, "save_config", %{
          "domain" => "min.example.com",
          "min_healthy" => "1",
          "artifact_type" => "unauthenticated_url",
          "path_prefix" => ""
        })

      assert html =~ "Configuration saved"
      assert html =~ "min.example.com"
      assert render(lv) =~ "api"
    end

    test "surfaces a configuration error", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button[phx-click=open_config]") |> render_click()
      html = lv |> form("#edit-config-form", %{domain: ""}) |> render_submit()

      assert html =~ "check the fields"
    end

    test "opens then cancels the config dialog", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      assert lv |> element("button[phx-click=open_config]") |> render_click() =~ "Edit api"
      refute lv |> element("#edit-config button", "Cancel") |> render_click() =~ "Edit api"
    end

    test "edits environment variables", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button[phx-click=open_env]") |> render_click()
      lv |> element("button", "+ Add variable") |> render_click()

      html =
        lv
        |> form("#edit-env-form", %{env: %{"0" => %{key: "FOO", value: "bar"}}})
        |> render_submit()

      assert html =~ "Environment saved"
      assert html =~ "FOO"
      assert render(lv) =~ "api"
    end

    test "normalizes env var names on save", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button[phx-click=open_env]") |> render_click()
      lv |> element("button", "+ Add variable") |> render_click()

      html =
        lv
        |> form("#edit-env-form", %{env: %{"0" => %{key: "database-url", value: "x"}}})
        |> render_submit()

      assert html =~ "Environment saved"

      assert Still.Applications.get_application_by_name("api").env_vars == %{
               "DATABASE_URL" => "x"
             }

      # Flush the LV's pending reload so its async DB read doesn't race teardown.
      render(lv)
    end

    test "preloads existing environment variables into the editor", %{conn: conn} do
      application_fixture(%{name: "api", env_vars: %{"FOO" => "bar"}})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      html = lv |> element("button[phx-click=open_env]") |> render_click()
      assert html =~ "Environment for api"
      assert html =~ ~s(value="FOO")
    end

    test "adds, syncs, and removes env rows", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button[phx-click=open_env]") |> render_click()
      lv |> element("button", "+ Add variable") |> render_click()

      assert lv
             |> form("#edit-env-form", %{env: %{"0" => %{key: "FOO", value: "bar"}}})
             |> render_change() =~ "FOO"

      assert lv |> element("#edit-env button[phx-click=remove_env_row]") |> render_click() =~
               "No variables."
    end

    test "rejects a value without a key", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button[phx-click=open_env]") |> render_click()
      lv |> element("button", "+ Add variable") |> render_click()

      assert lv
             |> form("#edit-env-form", %{env: %{"0" => %{key: "", value: "orphan"}}})
             |> render_submit() =~ "Every value needs a key."
    end

    test "rejects duplicate keys", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button[phx-click=open_env]") |> render_click()
      lv |> element("button", "+ Add variable") |> render_click()
      lv |> element("button", "+ Add variable") |> render_click()

      assert lv
             |> form("#edit-env-form", %{
               env: %{"0" => %{key: "DUP", value: "a"}, "1" => %{key: "DUP", value: "b"}}
             })
             |> render_submit() =~ "Duplicate keys"
    end

    test "opens then cancels the env dialog", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      assert lv |> element("button[phx-click=open_env]") |> render_click() =~ "Environment for"
      refute lv |> element("#edit-env button", "Cancel") |> render_click() =~ "Environment for"
    end

    test "adds a hook", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Add hook") |> render_click()
      lv |> element("#hook-form-form button", "post_deploy") |> render_click()

      assert lv
             |> form("#hook-form-form", %{hook: %{script: "", timeout_ms: "30000"}})
             |> render_submit() =~ "can&#39;t be blank"

      html =
        lv
        |> form("#hook-form-form", %{hook: %{script: "echo hi", timeout_ms: "30000"}})
        |> render_submit()

      assert html =~ "Hook saved"
      assert html =~ "post_deploy"
    end

    test "edits a hook", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      hook = hook_fixture(app, %{event: :pre_deploy, script: "old script"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("#hook-#{hook.id} button", "Edit") |> render_click()

      assert lv
             |> form("#hook-form-form", %{hook: %{script: "", timeout_ms: "1000"}})
             |> render_submit() =~ "can&#39;t be blank"

      html =
        lv
        |> form("#hook-form-form", %{hook: %{script: "new script", timeout_ms: "2000"}})
        |> render_submit()

      assert html =~ "Hook saved"
      assert html =~ "new script"
    end

    test "deletes a hook", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      hook = hook_fixture(app, %{event: :pre_deploy})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("#hook-#{hook.id} button", "Delete") |> render_click()
      assert render(lv) =~ "removed from this application"

      html = lv |> element("#delete-hook button", "Delete") |> render_click()
      assert html =~ "pre_deploy hook deleted"
      assert html =~ "No lifecycle hooks configured."
    end

    test "opens then cancels the hook dialog", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      assert lv |> element("button", "Add hook") |> render_click() =~ "Add a lifecycle hook"

      refute lv |> element("#hook-form button", "Cancel") |> render_click() =~
               "Add a lifecycle hook"
    end

    test "opens then cancels hook deletion", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      hook = hook_fixture(app, %{event: :pre_deploy})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      assert lv |> element("#hook-#{hook.id} button", "Delete") |> render_click() =~
               "removed from this application"

      refute lv |> element("#delete-hook button", "Cancel") |> render_click() =~
               "removed from this application"
    end
  end

  describe "deploy and rollback" do
    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})

      start_supervised!(
        {Orchestrator,
         agent_caller: fn _node, spec -> {:ok, spec.version} end,
         rollback_agent_caller: fn _node, spec -> {:ok, spec.version} end,
         artifact_stager: fn _app, _dep -> :ok end,
         notifier: self(),
         skip_orphan_recovery: true}
      )

      %{conn: log_in_user(conn, admin)}
    end

    defp assigned_app(name) do
      app = application_fixture(%{name: name})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      AgentConnectionManager.agent_connected(%{
        server_id: server.id,
        node: :a@h,
        connected_at: DateTime.utc_now(),
        applications: []
      })

      :sys.get_state(AgentConnectionManager)
      app
    end

    test "starts a deploy and navigates to it", %{conn: conn} do
      assigned_app("api")

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Deploy") |> render_click()

      result =
        lv
        |> form("#deploy-form", %{
          deploy: %{version: "1.0.0", artifact_url: "https://example.com/app.tar.gz", source: ""}
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/deployments/" <> _}}} = result
      # Wait out the background deploy task so it doesn't race the DB teardown.
      assert_receive {:deployment_complete, _id, _status}, 2_000
    end

    test "requires a server before deploying", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Deploy") |> render_click()

      html =
        lv
        |> form("#deploy-form", %{
          deploy: %{version: "1.0.0", artifact_url: "https://example.com/app.tar.gz", source: ""}
        })
        |> render_submit()

      assert html =~ "Assign a server before deploying."
    end

    test "surfaces a deploy validation error", %{conn: conn} do
      assigned_app("api")

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Deploy") |> render_click()

      html =
        lv
        |> form("#deploy-form", %{
          deploy: %{version: "", artifact_url: "https://example.com/app.tar.gz", source: ""}
        })
        |> render_submit()

      assert html =~ "check the version"
    end

    test "rolls back to the previous version", %{conn: conn} do
      app = assigned_app("api")
      app |> deployment_fixture(%{version: "1.0.0"}) |> Deployments.complete_deployment!()
      app |> deployment_fixture(%{version: "2.0.0"}) |> Deployments.complete_deployment!()

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Roll back") |> render_click()
      result = lv |> element("#rollback button", "Roll back") |> render_click()

      assert {:error, {:live_redirect, %{to: "/deployments/" <> _}}} = result
      assert_receive {:deployment_complete, _id, _status}, 2_000
    end

    test "rejects a rollback with no target", %{conn: conn} do
      assigned_app("api")

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      lv |> element("button", "Roll back") |> render_click()
      html = lv |> element("#rollback button", "Roll back") |> render_click()

      assert html =~ "No previous successful version"
    end

    test "opens then cancels the deploy and rollback dialogs", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      assert lv |> element("button", "Deploy") |> render_click() =~ "Triggers a rolling deploy"

      refute lv |> element("#deploy button", "Cancel") |> render_click() =~
               "Triggers a rolling deploy"

      assert lv |> element("button", "Roll back") |> render_click() =~
               "previous successful version"

      refute lv |> element("#rollback button", "Cancel") |> render_click() =~
               "previous successful version"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/applications/api")
      assert path == ~p"/users/log-in"
    end
  end

  describe "permission guards" do
    setup :register_and_log_in_user

    test "rejects unauthorized admin, deploy, and rollback events", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/applications/api")

      assert render_hook(lv, "open_delete", %{}) =~ "Admin permission required."

      assert render_hook(lv, "assign_server", %{"server_id" => Ecto.UUID.generate()}) =~
               "Admin permission required."

      assert render_hook(lv, "open_deploy", %{}) =~ "Deploy permission required."
      assert render_hook(lv, "open_rollback", %{}) =~ "Rollback permission required."
    end
  end
end
