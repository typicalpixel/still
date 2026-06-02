defmodule StillWeb.DeploymentsLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.ApplicationsFixtures
  import Still.DeploymentsFixtures
  import Still.FleetFixtures

  alias Still.AccountsFixtures
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Orchestrator

  defp broadcast_event(type) do
    Phoenix.PubSub.broadcast(
      Still.PubSub,
      "events:lobby",
      {:event_recorded, %{id: "e-#{type}", type: type, at: DateTime.utc_now()}}
    )
  end

  defp setup_deploys(_context) do
    api = application_fixture(%{name: "api"})
    web = application_fixture(%{name: "web"})
    server = server_fixture(%{name: "s1"})
    {:ok, _} = Applications.assign_server(Actor.system(), api, server)
    {:ok, _} = Applications.assign_server(Actor.system(), web, server)

    completed = api |> deployment_fixture() |> Deployments.complete_deployment!()
    inflight = api |> deployment_fixture() |> Deployments.start_deployment!()
    failed = api |> deployment_fixture() |> Deployments.fail_deployment!("boom")
    web_deploy = web |> deployment_fixture() |> Deployments.complete_deployment!()

    %{api: api, completed: completed, inflight: inflight, failed: failed, web_deploy: web_deploy}
  end

  defp short(deployment), do: String.slice(deployment.id, 0, 8)

  describe "deployments list" do
    setup [:register_and_log_in_user, :setup_deploys]

    test "lists deployments across applications", %{conn: conn, completed: c, web_deploy: w} do
      {:ok, _lv, html} = live(conn, ~p"/deployments")

      assert html =~ "Deployments"
      assert html =~ "4 most recent"
      assert html =~ "1 in flight"
      assert html =~ "api"
      assert html =~ "web"
      assert html =~ short(c)
      assert html =~ short(w)
      # The status tabs link to the filtered views.
      assert html =~ "/deployments?status=failed"
    end

    test "filters to in-flight deploys", %{conn: conn, inflight: i, completed: c} do
      {:ok, _lv, html} = live(conn, ~p"/deployments?status=in_flight")

      assert html =~ short(i)
      refute html =~ short(c)
    end

    test "filters to failed deploys", %{conn: conn, failed: f, completed: c} do
      {:ok, _lv, html} = live(conn, ~p"/deployments?status=failed")

      assert html =~ short(f)
      refute html =~ short(c)
      # Only failed rows came back, so the in-flight tally is zero.
      assert html =~ "0 in flight"
    end

    test "filters by application and clears via the chip", %{
      conn: conn,
      completed: c,
      web_deploy: w
    } do
      {:ok, lv, html} = live(conn, ~p"/deployments?application=api")

      assert html =~ "application: api"
      assert html =~ short(c)
      refute html =~ short(w)

      # Combining the application filter with a status tab keeps both.
      html = render_patch(lv, ~p"/deployments?application=api&status=failed")
      assert html =~ "application: api"

      # Clearing the chip drops back to every application.
      html = render_patch(lv, ~p"/deployments")
      assert html =~ short(w)
    end

    test "reloads on deploy events and ignores unrelated activity", %{conn: conn, api: api} do
      {:ok, lv, _html} = live(conn, ~p"/deployments")

      # Unrelated activity doesn't reload the list, but the page stays alive.
      broadcast_event(:health_transition)
      assert render(lv) =~ "Deployments"

      # A deploy-lifecycle event reloads the list, picking up the new row.
      new = deployment_fixture(api)
      broadcast_event(:deploy_initiated)
      assert render(lv) =~ short(new)
    end
  end

  describe "empty" do
    setup :register_and_log_in_user

    test "shows an empty notice when nothing matches", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/deployments")

      assert html =~ "No deployments match this filter."
      assert html =~ "0 in flight"
    end
  end

  describe "start deploy" do
    setup %{conn: conn} do
      start_supervised!(AgentConnectionManager)

      start_supervised!(
        {Orchestrator,
         agent_caller: fn _node, spec -> {:ok, spec.version} end,
         rollback_agent_caller: fn _node, spec -> {:ok, spec.version} end,
         artifact_stager: fn _app, _dep -> :ok end,
         notifier: self(),
         skip_orphan_recovery: true}
      )

      admin = AccountsFixtures.user_fixture(%{role: :admin})
      %{conn: log_in_user(conn, admin)}
    end

    defp connect(server) do
      AgentConnectionManager.agent_connected(%{
        server_id: server.id,
        node: :a@h,
        connected_at: DateTime.utc_now(),
        applications: []
      })

      :sys.get_state(AgentConnectionManager)
    end

    test "shows the start-deploy button to deployers", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/deployments")
      assert html =~ "Start deploy"
    end

    test "starts a deploy against the chosen application and navigates", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)
      connect(server)

      {:ok, lv, _html} = live(conn, ~p"/deployments")
      lv |> element("button", "Start deploy") |> render_click()

      result =
        lv
        |> form("#start-deploy-form", %{
          deploy: %{
            application: "api",
            version: "1.0.0",
            artifact_url: "https://example.com/app.tar.gz",
            source: "git:main@abc1234"
          }
        })
        |> render_submit()

      assert {:error, {:live_redirect, %{to: "/deployments/" <> _}}} = result
      # Wait out the background deploy task so it doesn't race the DB teardown.
      assert_receive {:deployment_complete, _id, _status}, 2_000
    end

    test "requires choosing an application", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/deployments")
      lv |> element("button", "Start deploy") |> render_click()

      html =
        lv
        |> form("#start-deploy-form", %{
          deploy: %{
            application: "",
            version: "1.0.0",
            artifact_url: "https://x/a.tar.gz",
            source: ""
          }
        })
        |> render_submit()

      assert html =~ "Pick an application."
    end

    test "requires a server before deploying", %{conn: conn} do
      application_fixture(%{name: "api"})

      {:ok, lv, _html} = live(conn, ~p"/deployments")
      lv |> element("button", "Start deploy") |> render_click()

      html =
        lv
        |> form("#start-deploy-form", %{
          deploy: %{
            application: "api",
            version: "1.0.0",
            artifact_url: "https://x/a.tar.gz",
            source: ""
          }
        })
        |> render_submit()

      assert html =~ "Assign a server"
    end

    test "surfaces a deploy validation error", %{conn: conn} do
      app = application_fixture(%{name: "api"})
      server = server_fixture(%{name: "s1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)
      connect(server)

      {:ok, lv, _html} = live(conn, ~p"/deployments")
      lv |> element("button", "Start deploy") |> render_click()

      html =
        lv
        |> form("#start-deploy-form", %{
          deploy: %{
            application: "api",
            version: "",
            artifact_url: "https://x/a.tar.gz",
            source: ""
          }
        })
        |> render_submit()

      assert html =~ "check the version"
    end

    test "opens then cancels the dialog", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/deployments")

      assert lv |> element("button", "Start deploy") |> render_click() =~ "Start a deploy"
      refute lv |> element("#start-deploy button", "Cancel") |> render_click() =~ "Start a deploy"
    end
  end

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/deployments")
      assert path == ~p"/users/log-in"
    end
  end
end
