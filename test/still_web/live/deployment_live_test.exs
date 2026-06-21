defmodule StillWeb.DeploymentLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest
  import Still.ApplicationsFixtures
  import Still.DeploymentsFixtures
  import Still.FleetFixtures

  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Deployments

  defp deployment_update(app_name, deployment_id) do
    Phoenix.PubSub.broadcast(
      Still.PubSub,
      "deployments:#{app_name}",
      {:deployment_updated, %{deployment_id: deployment_id}}
    )
  end

  defp finish_step(deployment_id, server_id) do
    deployment_id
    |> Deployments.get_step_for_server!(server_id)
    |> Deployments.start_deployment_step!()
    |> Deployments.complete_deployment_step!()
  end

  describe "deployment detail" do
    setup :register_and_log_in_user

    setup do
      api = application_fixture(%{name: "api"})
      s1 = server_fixture(%{name: "s1"})
      s2 = server_fixture(%{name: "s2"})
      {:ok, _} = Applications.assign_server(Actor.system(), api, s1)
      {:ok, _} = Applications.assign_server(Actor.system(), api, s2)

      %{api: api, s1: s1, s2: s2}
    end

    test "renders an in-flight deployment with progress and per-host steps", %{
      conn: conn,
      api: api,
      s1: s1
    } do
      deploy = api |> deployment_fixture() |> Deployments.start_deployment!()
      finish_step(deploy.id, s1.id)

      {:ok, _lv, html} = live(conn, ~p"/deployments/#{deploy.id}")

      assert html =~ "api"
      assert html =~ deploy.version
      assert html =~ "Overall progress"
      assert html =~ "1 / 2 hosts"
      assert html =~ "50% complete"
      assert html =~ "Per-host steps"
      assert html =~ "s1"
      assert html =~ "s2"
      assert html =~ "Live log"
      assert html =~ "completed"
      assert html =~ "pending"
    end

    test "renders a finished deployment and gates its log behind deploy permission", %{
      conn: conn,
      api: api
    } do
      deploy =
        api
        |> deployment_fixture()
        |> Deployments.start_deployment!()
        |> Deployments.complete_deployment!()

      {:ok, _lv, html} = live(conn, ~p"/deployments/#{deploy.id}")

      assert html =~ "succeeded"
      assert html =~ "took"
      assert html =~ "Log"
      # The default fixture user is a viewer — the log panel is withheld.
      assert html =~ "requires deploy permission"
    end

    test "withholds the actual log bytes from a viewer even when a log exists", %{
      conn: conn,
      api: api,
      s1: s1
    } do
      deploy =
        api
        |> deployment_fixture()
        |> Deployments.start_deployment!()
        |> Deployments.fail_deployment!("x")

      {:ok, _} =
        Deployments.put_step_log(deploy.id, s1.id, "DATABASE_URL=postgres://app:s3cr3t@db/app")

      {:ok, _lv, html} = live(conn, ~p"/deployments/#{deploy.id}")

      assert html =~ "requires deploy permission"
      # The secret in the captured boot log must never reach a :read-only user.
      refute html =~ "s3cr3t"
    end

    test "reloads as its own steps transition and ignores sibling deploys", %{
      conn: conn,
      api: api,
      s1: s1
    } do
      deploy = api |> deployment_fixture() |> Deployments.start_deployment!()

      {:ok, lv, html} = live(conn, ~p"/deployments/#{deploy.id}")
      assert html =~ "0 / 2 hosts"

      # A sibling deploy on the same application (different id) is ignored.
      deployment_update("api", Ecto.UUID.generate())
      assert render(lv) =~ "0 / 2 hosts"

      # This deploy's own update reloads — a completed step bumps progress.
      finish_step(deploy.id, s1.id)
      deployment_update("api", deploy.id)
      assert render(lv) =~ "1 / 2 hosts"
    end

    test "renders not-found for unknown or malformed ids", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/deployments/#{Ecto.UUID.generate()}")
      assert html =~ "Deployment not found"

      {:ok, _lv, html} = live(conn, ~p"/deployments/nope")
      assert html =~ "Deployment not found"
    end
  end

  describe "deployment detail — with deploy permission" do
    setup %{conn: conn} do
      admin = Still.AccountsFixtures.user_fixture(%{role: :admin})
      api = application_fixture(%{name: "store"})
      s1 = server_fixture(%{name: "host-1"})
      {:ok, _} = Applications.assign_server(Actor.system(), api, s1)
      %{conn: log_in_user(conn, admin), api: api, s1: s1}
    end

    test "renders the stored deploy log and a failure-signature hint", %{
      conn: conn,
      api: api,
      s1: s1
    } do
      deploy =
        api
        |> deployment_fixture()
        |> Deployments.start_deployment!()
        |> Deployments.fail_deployment!("boot failed")

      {:ok, _} =
        Deployments.put_step_log(
          deploy.id,
          s1.id,
          "booting release\nname store@host seems to be in use by another Erlang node"
        )

      {:ok, _lv, html} = live(conn, ~p"/deployments/#{deploy.id}")

      refute html =~ "requires deploy permission"
      assert html =~ "seems to be in use"
      assert html =~ "Node-name collision"
    end

    test "shows no hint for a successful deploy even if the log would match", %{
      conn: conn,
      api: api,
      s1: s1
    } do
      deploy =
        api
        |> deployment_fixture()
        |> Deployments.start_deployment!()
        |> Deployments.complete_deployment!()

      {:ok, _} = Deployments.put_step_log(deploy.id, s1.id, "seems to be in use by another")

      {:ok, _lv, html} = live(conn, ~p"/deployments/#{deploy.id}")

      assert html =~ "seems to be in use"
      refute html =~ "Node-name collision"
    end

    test "re-reads the log when an agent reports new journal", %{conn: conn, api: api, s1: s1} do
      deploy =
        api |> deployment_fixture() |> Deployments.start_deployment!() |> fail("x")

      {:ok, _} = Deployments.put_step_log(deploy.id, s1.id, "first capture")
      {:ok, lv, html} = live(conn, ~p"/deployments/#{deploy.id}")
      assert html =~ "first capture"

      {:ok, _} = Deployments.put_step_log(deploy.id, s1.id, "second capture surfaced")

      Phoenix.PubSub.broadcast(
        Still.PubSub,
        "deploy_logs:#{deploy.id}",
        {:deploy_log_updated, %{deployment_id: deploy.id}}
      )

      assert render(lv) =~ "second capture surfaced"
    end

    test "shows the no-log note when nothing was captured", %{conn: conn, api: api} do
      deploy = api |> deployment_fixture() |> Deployments.start_deployment!() |> fail("x")

      {:ok, _lv, html} = live(conn, ~p"/deployments/#{deploy.id}")
      assert html =~ "No deploy log was captured."
    end

    test "groups captured logs per host across a multi-server deploy", %{conn: conn} do
      multi = application_fixture(%{name: "multi"})
      alpha = server_fixture(%{name: "alpha"})
      bravo = server_fixture(%{name: "bravo"})
      {:ok, _} = Applications.assign_server(Actor.system(), multi, alpha)
      {:ok, _} = Applications.assign_server(Actor.system(), multi, bravo)

      deploy = multi |> deployment_fixture() |> Deployments.start_deployment!() |> fail("x")
      {:ok, _} = Deployments.put_step_log(deploy.id, alpha.id, "alpha booting")
      {:ok, _} = Deployments.put_step_log(deploy.id, bravo.id, "bravo booting")

      {:ok, _lv, html} = live(conn, ~p"/deployments/#{deploy.id}")

      assert html =~ "── alpha ──"
      assert html =~ "alpha booting"
      assert html =~ "bravo booting"
    end
  end

  defp fail(deployment, reason), do: Deployments.fail_deployment!(deployment, reason)

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/deployments/#{Ecto.UUID.generate()}")

      assert path == ~p"/users/log-in"
    end
  end
end
