defmodule StillWeb.ApplicationsLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.ApplicationsFixtures
  import Still.DeploymentsFixtures
  import Still.FleetFixtures

  alias Still.AccountsFixtures
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.CaddyMetricsScraper
  alias Still.Events
  alias Still.MetricsCollector

  setup do
    start_supervised!(AgentConnectionManager)
    start_supervised!(MetricsCollector)

    start_supervised!(
      {CaddyMetricsScraper, interval_ms: 60_000, http_getter: fn _ -> {:ok, ""} end}
    )

    :ok
  end

  describe "applications list" do
    setup :register_and_log_in_user

    test "renders an empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/applications")

      assert html =~ "Applications"
      assert html =~ "No applications yet."
      assert html =~ "0 applications · 0 healthy"
    end

    test "lists applications with type, version, and health", %{conn: conn} do
      app = application_fixture(%{name: "api", min_healthy: 1})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)
      Applications.set_desired_version_for_all(app, "1.0.0")

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

      {:ok, _lv, html} = live(conn, ~p"/applications")

      assert html =~ "api"
      assert html =~ "elixir"
      assert html =~ "1.0.0"
      assert html =~ "1 applications · 1 healthy"
    end

    test "reloads on deploy, server, and fleet events", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)
      _deploy = deployment_fixture(app)

      {:ok, lv, _html} = live(conn, ~p"/applications")

      Phoenix.PubSub.broadcast(
        Still.PubSub,
        "events:lobby",
        {:event_recorded,
         %{
           id: "e1",
           type: :deployment_updated,
           payload: %{application_name: "api"},
           at: DateTime.utc_now()
         }}
      )

      Phoenix.PubSub.broadcast(
        Still.PubSub,
        "events:lobby",
        {:event_recorded,
         %{id: "e2", type: :server_connected, payload: %{server_id: "s1"}, at: DateTime.utc_now()}}
      )

      Events.server_connected("s1", :a@h)
      Events.server_disconnected("s1")
      Events.fleet_changed()

      assert render(lv) =~ "api"
    end
  end

  describe "create application" do
    setup %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role: :admin})
      %{conn: log_in_user(conn, admin)}
    end

    test "shows the add-application button to admins", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/applications")
      assert html =~ "Add application"
    end

    test "creates an elixir_release application and navigates to it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/applications")
      lv |> element("button", "Add application") |> render_click()

      result =
        lv
        |> form("#create-app-form", %{
          app: %{
            name: "orchard-api",
            domain: "api.orchard.io",
            path_prefix: "/v1",
            exec_command: "bin/orchard start",
            min_healthy: "1",
            hc_path: "/health",
            hc_interval: "5000",
            hc_deadline: "3000",
            artifact_type: "unauthenticated_url"
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/applications/orchard-api"}}} = result
      app = Applications.get_application_by_name("orchard-api")
      assert app.type == :elixir_release
      assert app.exec_command == "bin/orchard start"
    end

    test "creates a static_site application without exec or health fields", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/applications")
      lv |> element("button", "Add application") |> render_click()
      lv |> element("#create-app button", "Static site") |> render_click()

      result =
        lv
        |> form("#create-app-form", %{
          app: %{
            name: "marketing",
            domain: "www.orchard.io",
            path_prefix: "",
            min_healthy: "1",
            artifact_type: "unauthenticated_url"
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/applications/marketing"}}} = result
      app = Applications.get_application_by_name("marketing")
      assert app.type == :static_site
      assert app.exec_command == nil
      assert app.health_check == nil
    end

    test "creates an application with normalized environment variables", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/applications")
      lv |> element("button", "Add application") |> render_click()
      lv |> element("#create-app button", "+ Add variable") |> render_click()

      result =
        lv
        |> form("#create-app-form", %{
          app: %{
            name: "orchard-api",
            domain: "api.orchard.io",
            path_prefix: "",
            exec_command: "bin/orchard start",
            min_healthy: "1",
            hc_path: "/health",
            hc_interval: "5000",
            hc_deadline: "3000",
            artifact_type: "unauthenticated_url"
          },
          env: %{"0" => %{key: "database-url", value: "ecto://localhost/app"}}
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/applications/orchard-api"}}} = result
      app = Applications.get_application_by_name("orchard-api")
      assert app.env_vars == %{"DATABASE_URL" => "ecto://localhost/app"}
    end

    test "rejects creation when an env value has no key", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/applications")
      lv |> element("button", "Add application") |> render_click()
      lv |> element("#create-app button", "+ Add variable") |> render_click()

      html =
        lv
        |> form("#create-app-form", %{
          app: %{
            name: "orchard-api",
            domain: "api.orchard.io",
            path_prefix: "",
            exec_command: "bin/orchard start",
            min_healthy: "1",
            hc_path: "/health",
            hc_interval: "5000",
            hc_deadline: "3000",
            artifact_type: "unauthenticated_url"
          },
          env: %{"0" => %{key: "", value: "orphan"}}
        })
        |> render_submit()

      assert html =~ "Every value needs a key."
      assert Applications.get_application_by_name("orchard-api") == nil
    end

    test "adds, syncs, and removes env rows in the create dialog", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/applications")
      lv |> element("button", "Add application") |> render_click()

      assert lv |> element("#create-app button", "+ Add variable") |> render_click() =~
               ~s(name="env[0][key]")

      assert lv
             |> form("#create-app-form", %{env: %{"0" => %{key: "FOO", value: "bar"}}})
             |> render_change() =~ ~s(value="FOO")

      assert lv |> element("#create-app button[phx-click=remove_env_row]") |> render_click() =~
               "No variables."
    end

    test "surfaces validation errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/applications")
      lv |> element("button", "Add application") |> render_click()

      html =
        lv
        |> form("#create-app-form", %{
          app: %{
            name: "",
            domain: "",
            path_prefix: "",
            exec_command: "bin/start",
            min_healthy: "1",
            hc_path: "/health",
            hc_interval: "5000",
            hc_deadline: "3000",
            artifact_type: "unauthenticated_url"
          }
        })
        |> render_submit()

      assert html =~ "name"
      assert html =~ "can&#39;t be blank"
    end

    test "opens then cancels the dialog", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/applications")

      assert lv |> element("button", "Add application") |> render_click() =~
               "Create an application"

      refute lv |> element("#create-app button", "Cancel") |> render_click() =~
               "Create an application"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/applications")
      assert path == ~p"/users/log-in"
    end
  end
end
