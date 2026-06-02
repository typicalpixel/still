defmodule Still.ReconciliationLoopTest do
  use Still.DataCase, async: false

  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.ReconciliationLoop

  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  setup do
    test_pid = self()

    acm = start_supervised!(AgentConnectionManager)

    rl =
      start_supervised!(
        {ReconciliationLoop,
         interval_ms: 60_000, on_drift: fn entries -> send(test_pid, {:drift, entries}) end}
      )

    %{acm: acm, rl: rl}
  end

  defp register_agent(server_id, applications) do
    AgentConnectionManager.agent_connected(%{
      server_id: server_id,
      node: :fake@host,
      connected_at: DateTime.utc_now(),
      applications: applications
    })

    :sys.get_state(AgentConnectionManager)
  end

  describe "reconcile_now/0 — no assignments" do
    test "returns an empty list when there are no application servers" do
      assert [] == ReconciliationLoop.reconcile_now()
    end
  end

  describe "reconcile_now/0 — not_deployed" do
    test "returns :not_deployed when desired_version is nil" do
      app = application_fixture()
      server = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      results = ReconciliationLoop.reconcile_now()

      assert [%{status: :not_deployed, desired_version: nil}] = results
    end
  end

  describe "reconcile_now/0 — agent_disconnected" do
    test "returns :agent_disconnected when the agent is not in ETS" do
      app = application_fixture()
      server = server_fixture()
      {:ok, as} = Applications.assign_server(Actor.system(), app, server)
      {:ok, _} = Applications.set_desired_version(as, "1.0.0")

      results = ReconciliationLoop.reconcile_now()

      assert [%{status: :agent_disconnected, desired_version: "1.0.0"}] = results
    end
  end

  describe "reconcile_now/0 — in_sync" do
    test "returns :in_sync when desired == actual" do
      app = application_fixture()
      server = server_fixture()
      {:ok, as} = Applications.assign_server(Actor.system(), app, server)
      {:ok, _} = Applications.set_desired_version(as, "1.0.0")

      register_agent(server.id, [
        %{application_name: app.name, current_version: "1.0.0"}
      ])

      results = ReconciliationLoop.reconcile_now()

      assert [%{status: :in_sync, desired_version: "1.0.0", actual_version: "1.0.0"}] = results
    end
  end

  describe "reconcile_now/0 — drifted" do
    @tag :capture_log
    test "returns :drifted when desired != actual and calls on_drift" do
      app = application_fixture()
      server = server_fixture()
      {:ok, as} = Applications.assign_server(Actor.system(), app, server)
      {:ok, _} = Applications.set_desired_version(as, "2.0.0")

      register_agent(server.id, [
        %{application_name: app.name, current_version: "1.0.0"}
      ])

      results = ReconciliationLoop.reconcile_now()

      assert [%{status: :drifted, desired_version: "2.0.0", actual_version: "1.0.0"}] = results

      assert_receive {:drift, [%{status: :drifted}]}
    end

    @tag :capture_log
    test "returns :drifted when agent is connected but app is missing from report" do
      app = application_fixture()
      server = server_fixture()
      {:ok, as} = Applications.assign_server(Actor.system(), app, server)
      {:ok, _} = Applications.set_desired_version(as, "1.0.0")

      register_agent(server.id, [])

      results = ReconciliationLoop.reconcile_now()

      assert [%{status: :drifted, actual_version: nil}] = results
    end
  end

  describe "reconcile_now/0 — multiple assignments" do
    @tag :capture_log
    test "returns a mix of statuses across apps and servers" do
      app1 = application_fixture()
      app2 = application_fixture()
      server1 = server_fixture()
      server2 = server_fixture()

      {:ok, as1} = Applications.assign_server(Actor.system(), app1, server1)
      {:ok, _as2} = Applications.assign_server(Actor.system(), app2, server2)

      {:ok, _} = Applications.set_desired_version(as1, "1.0.0")

      register_agent(server1.id, [
        %{application_name: app1.name, current_version: "1.0.0"}
      ])

      results = ReconciliationLoop.reconcile_now()
      statuses = Enum.map(results, & &1.status) |> Enum.sort()

      assert :in_sync in statuses
      assert :not_deployed in statuses
    end
  end

  describe "default_on_drift logging" do
    @tag :capture_log
    test "logs drift entries when using the default on_drift callback" do
      stop_supervised!(ReconciliationLoop)
      start_supervised!({ReconciliationLoop, interval_ms: 60_000})

      app = application_fixture()
      server = server_fixture()
      {:ok, as} = Applications.assign_server(Actor.system(), app, server)
      {:ok, _} = Applications.set_desired_version(as, "1.0.0")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ReconciliationLoop.reconcile_now()
        end)

      assert log =~ "drift:"
      assert log =~ "agent_disconnected"
    end
  end

  describe "periodic timer" do
    @tag :capture_log
    test "fires automatically based on interval_ms" do
      stop_supervised!(ReconciliationLoop)
      test_pid = self()

      start_supervised!(
        {ReconciliationLoop,
         interval_ms: 50, on_drift: fn entries -> send(test_pid, {:drift, entries}) end}
      )

      app = application_fixture()
      server = server_fixture()
      {:ok, as} = Applications.assign_server(Actor.system(), app, server)
      {:ok, _} = Applications.set_desired_version(as, "1.0.0")

      # No agent registered → drift should be detected on the next tick
      assert_receive {:drift, [%{status: :agent_disconnected}]}, 500
    end
  end
end
