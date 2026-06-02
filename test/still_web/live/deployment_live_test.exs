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

    test "renders a finished deployment with its duration and log", %{conn: conn, api: api} do
      deploy =
        api
        |> deployment_fixture()
        |> Deployments.start_deployment!()
        |> Deployments.complete_deployment!()

      {:ok, _lv, html} = live(conn, ~p"/deployments/#{deploy.id}")

      assert html =~ "succeeded"
      assert html =~ "took"
      assert html =~ "Log"
      assert html =~ "last activity"
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

  describe "unauthenticated" do
    test "redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/deployments/#{Ecto.UUID.generate()}")

      assert path == ~p"/users/log-in"
    end
  end
end
