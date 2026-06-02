defmodule Still.OrchestratorTest do
  use Still.DataCase, async: false

  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Deployments.Deployment
  alias Still.Orchestrator

  import ExUnit.CaptureLog
  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  setup do
    start_supervised!(AgentConnectionManager)
    :ok
  end

  defp setup_app_with_server do
    app = application_fixture()
    server = server_fixture()
    {:ok, _as} = Applications.assign_server(Actor.system(), app, server)
    register_agent(server.id)
    {app, server}
  end

  defp register_agent(server_id) do
    AgentConnectionManager.agent_connected(%{
      server_id: server_id,
      node: :fake@host,
      connected_at: DateTime.utc_now(),
      applications: []
    })

    :sys.get_state(AgentConnectionManager)
  end

  defp start_orchestrator(agent_caller, rollback_caller \\ nil) do
    opts = [
      agent_caller: agent_caller,
      artifact_stager: fn _app, _dep -> :ok end,
      notifier: self()
    ]

    opts =
      if rollback_caller,
        do: Keyword.put(opts, :rollback_agent_caller, rollback_caller),
        else: opts

    start_supervised!({Orchestrator, opts})
  end

  defp deploy_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        version: "1.0.0+abc",
        artifact_url: "https://example.com/app.tar.gz",
        initiated_by: "test"
      },
      overrides
    )
  end

  describe "init/1 — orphan recovery" do
    test "marks in_progress deployments as failed on boot" do
      {app, _server} = setup_app_with_server()

      orphan =
        Deployments.create_deployment(Actor.system(), app, %{
          version: "0.9.0",
          artifact_url: "https://example.com/a.tar.gz",
          initiated_by: "test"
        })
        |> then(fn {:ok, d} -> Deployments.start_deployment!(d) end)

      assert orphan.status == :in_progress

      log = capture_log(fn -> start_orchestrator(fn _n, s -> {:ok, s.version} end) end)
      assert log =~ "recovered 1 orphaned deployment"

      recovered = Deployments.get_deployment!(orphan.id)
      assert recovered.status == :failed
      assert %DateTime{} = recovered.completed_at

      [step] = Deployments.list_deployment_steps_for(recovered)
      assert step.status == :failed
      assert step.error == "controller_restart"
    end
  end

  describe "trigger_deployment/2 — happy path" do
    test "creates a deployment and completes it when the agent succeeds" do
      {app, _server} = setup_app_with_server()

      caller = fn _node, spec -> {:ok, spec.version} end
      start_orchestrator(caller)

      assert {:ok, %Deployment{} = deployment} =
               Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())

      assert deployment.status == :pending

      assert_receive {:deployment_complete, dep_id, :completed}, 1_000
      assert dep_id == deployment.id

      updated = Deployments.get_deployment!(deployment.id)
      assert updated.status == :completed
      assert %DateTime{} = updated.started_at
      assert %DateTime{} = updated.completed_at

      [step] = Deployments.list_deployment_steps_for(updated)
      assert step.status == :completed
      assert %DateTime{} = step.started_at
      assert %DateTime{} = step.completed_at

      [assignment] = Applications.list_application_servers(app)
      assert assignment.desired_version == deployment.version
    end
  end

  describe "trigger_deployment/2 — agent failure" do
    test "marks the deployment and step as failed when the agent returns an error" do
      {app, _server} = setup_app_with_server()

      caller = fn _node, _spec -> {:error, "health check timeout"} end
      start_orchestrator(caller)

      {:ok, deployment} = Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())

      log =
        capture_log(fn ->
          assert_receive {:deployment_complete, _, :failed}, 1_000
        end)

      assert log =~ "health check timeout"
      assert log =~ deployment.id

      updated = Deployments.get_deployment!(deployment.id)
      assert updated.status == :failed
      assert updated.error == "health check timeout"

      [step] = Deployments.list_deployment_steps_for(updated)
      assert step.status == :failed
      assert step.error == "health check timeout"
    end

    test "records the staging error on the deployment when artifact staging fails" do
      {app, _server} = setup_app_with_server()

      opts = [
        agent_caller: fn _n, s -> {:ok, s.version} end,
        artifact_stager: fn _app, _dep -> {:error, :http_404} end,
        notifier: self()
      ]

      start_supervised!({Orchestrator, opts})

      # Capture around the trigger too: staging is logged very early in the
      # background task (right after start_deployment!), so triggering before
      # opening the capture window races the log.
      log =
        capture_log(fn ->
          {:ok, _} = Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())
          assert_receive {:deployment_complete, _, :failed}, 1_000
        end)

      assert log =~ "artifact staging failed"
      assert log =~ ":http_404"
      assert log =~ "app.tar.gz"

      [updated] = Deployments.list_deployments(%{"application" => app.name})
      assert updated.status == :failed
      assert updated.error == ":http_404"
    end

    test "halts after the first failed server in a multi-server deployment" do
      app = application_fixture()
      server1 = server_fixture()
      server2 = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server1)
      {:ok, _} = Applications.assign_server(Actor.system(), app, server2)
      register_agent(server1.id)
      register_agent(server2.id)

      call_count = :counters.new(1, [:atomics])

      caller = fn _node, _spec ->
        n = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, n)
        if n == 1, do: {:error, "first server failed"}, else: {:ok, "1.0.0"}
      end

      start_orchestrator(caller)
      {:ok, deployment} = Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())

      capture_log(fn ->
        assert_receive {:deployment_complete, _, :failed}, 1_000
      end)

      assert Deployments.get_deployment!(deployment.id).status == :failed
      assert :counters.get(call_count, 1) == 1
    end

    test "halts with :agent_disconnected when an assigned server has no connected agent" do
      app = application_fixture(%{min_healthy: 1})
      server1 = server_fixture()
      server2 = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server1)
      {:ok, _} = Applications.assign_server(Actor.system(), app, server2)

      # Only server1 has a live agent. min_healthy=1 passes the precondition
      # check (1 connected >= 1 required), but the rolling loop still tries
      # to reach server2 and hits `nil` from AgentConnectionManager.
      register_agent(server1.id)

      caller = fn _node, spec -> {:ok, spec.version} end
      start_orchestrator(caller)

      {:ok, deployment} = Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())

      capture_log(fn ->
        assert_receive {:deployment_complete, _, :failed}, 1_000
      end)

      steps = Deployments.list_deployment_steps_for(Deployments.get_deployment!(deployment.id))
      server1_step = Enum.find(steps, &(&1.server_id == server1.id))
      server2_step = Enum.find(steps, &(&1.server_id == server2.id))

      assert server1_step.status == :completed
      assert server2_step.status == :failed
      assert server2_step.error == ":agent_disconnected"
    end
  end

  describe "trigger_deployment/2 — task crash containment" do
    test "a raising deploy task fails the deployment without taking down the orchestrator" do
      {app, _server} = setup_app_with_server()
      pid = start_orchestrator(fn _node, _spec -> raise "boom" end)

      {:ok, deployment} = Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())

      capture_log(fn ->
        assert_receive {:deployment_complete, _, :failed}, 1_000
      end)

      # The coordinator is still the same live process — the crash didn't
      # propagate through a link and restart it.
      assert Process.alive?(pid)
      assert Process.whereis(Orchestrator) == pid

      updated = Deployments.get_deployment!(deployment.id)
      assert updated.status == :failed
      assert updated.error =~ "boom"
    end

    test "an exiting deploy task is also contained and fails the deployment" do
      {app, _server} = setup_app_with_server()
      pid = start_orchestrator(fn _node, _spec -> exit(:boom) end)

      {:ok, deployment} = Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())

      capture_log(fn ->
        assert_receive {:deployment_complete, _, :failed}, 1_000
      end)

      assert Process.alive?(pid)

      updated = Deployments.get_deployment!(deployment.id)
      assert updated.status == :failed
    end
  end

  describe "trigger_deployment/2 — concurrency guard" do
    test "rejects a second deployment for the same app while one is in progress" do
      {app, _server} = setup_app_with_server()
      test_pid = self()

      caller = fn _node, spec ->
        send(test_pid, {:waiting, self()})
        receive do: (:proceed -> {:ok, spec.version})
      end

      start_orchestrator(caller)

      {:ok, _} =
        Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs(%{version: "1.0.0"}))

      assert_receive {:waiting, task_pid}, 1_000

      assert {:error, :deployment_in_progress} =
               Orchestrator.trigger_deployment(
                 Actor.system(),
                 app,
                 deploy_attrs(%{version: "2.0.0"})
               )

      send(task_pid, :proceed)
      assert_receive {:deployment_complete, _, :completed}, 1_000
    end

    test "allows a new deployment after the previous one completes" do
      {app, _server} = setup_app_with_server()

      caller = fn _node, spec -> {:ok, spec.version} end
      start_orchestrator(caller)

      {:ok, _} =
        Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs(%{version: "1.0.0"}))

      assert_receive {:deployment_complete, _, :completed}, 1_000

      {:ok, dep2} =
        Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs(%{version: "2.0.0"}))

      assert dep2.version == "2.0.0"

      assert_receive {:deployment_complete, _, :completed}, 1_000
    end
  end

  describe "trigger_deployment/2 — precondition failures" do
    test "returns :no_servers_assigned when no servers are assigned" do
      app = application_fixture()
      start_orchestrator(fn _n, _s -> {:ok, "v"} end)

      assert {:error, :no_servers_assigned} =
               Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())
    end

    test "returns :insufficient_healthy_agents when not enough agents are connected" do
      app = application_fixture(%{min_healthy: 2})
      server1 = server_fixture()
      server2 = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server1)
      {:ok, _} = Applications.assign_server(Actor.system(), app, server2)
      register_agent(server1.id)

      start_orchestrator(fn _n, _s -> {:ok, "v"} end)

      assert {:error, :insufficient_healthy_agents} =
               Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())
    end

    test "returns changeset error when deployment attributes are invalid" do
      {app, _server} = setup_app_with_server()
      start_orchestrator(fn _n, _s -> {:ok, "v"} end)

      assert {:error, %Ecto.Changeset{}} =
               Orchestrator.trigger_deployment(Actor.system(), app, %{})
    end
  end

  describe "trigger_deployment/2 — hook loading" do
    test "loads hooks from the DB into the deploy request keyed by event" do
      {app, _server} = setup_app_with_server()

      {:ok, _} =
        Applications.create_hook(Actor.system(), app, %{
          event: :pre_deploy,
          script: "echo before",
          timeout_ms: 10_000
        })

      {:ok, _} =
        Applications.create_hook(Actor.system(), app, %{
          event: :post_deploy,
          script: "echo after",
          timeout_ms: 20_000
        })

      test_pid = self()

      caller = fn _node, spec ->
        send(test_pid, {:deploy_request, spec})
        {:ok, spec.version}
      end

      start_orchestrator(caller)
      {:ok, _} = Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())

      assert_receive {:deploy_request, spec}, 1_000
      assert_receive {:deployment_complete, _, :completed}, 1_000

      assert spec.hooks[:pre_deploy] == %{script: "echo before", timeout_ms: 10_000}
      assert spec.hooks[:post_deploy] == %{script: "echo after", timeout_ms: 20_000}
      # Only the events that actually have hooks are present.
      refute Map.has_key?(spec.hooks, :pre_rollback)
      refute Map.has_key?(spec.hooks, :post_rollback)
    end

    test "sends an empty hooks map when the application has no hooks" do
      {app, _server} = setup_app_with_server()
      test_pid = self()

      caller = fn _node, spec ->
        send(test_pid, {:deploy_request, spec})
        {:ok, spec.version}
      end

      start_orchestrator(caller)
      {:ok, _} = Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs())

      assert_receive {:deploy_request, spec}, 1_000
      assert_receive {:deployment_complete, _, :completed}, 1_000

      assert spec.hooks == %{}
    end
  end

  describe "trigger_rollback/2" do
    test "creates a new deployment stamped with the previous successful version" do
      {app, _server} = setup_app_with_server()

      deploy_caller = fn _n, spec -> {:ok, spec.version} end

      rollback_spec_ref = :atomics.new(1, [])

      rollback_caller = fn _n, spec ->
        assert spec.application == app.name
        :atomics.put(rollback_spec_ref, 1, 1)
        {:ok, spec.version}
      end

      start_orchestrator(deploy_caller, rollback_caller)

      {:ok, _} =
        Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs(%{version: "1.0.0"}))

      assert_receive {:deployment_complete, _, :completed}, 1_000

      {:ok, _} =
        Orchestrator.trigger_deployment(
          Actor.system(),
          app,
          deploy_attrs(%{version: "2.0.0", artifact_url: "https://example.com/v2.tar.gz"})
        )

      assert_receive {:deployment_complete, _, :completed}, 1_000

      assert {:ok, %Deployment{} = rollback} =
               Orchestrator.trigger_rollback(Actor.system(), app, %{initiated_by: "test"})

      assert rollback.version == "1.0.0"
      assert rollback.artifact_url == "https://example.com/app.tar.gz"
      assert rollback.source == "rollback"

      assert_receive {:deployment_complete, _, :completed}, 1_000
      assert :atomics.get(rollback_spec_ref, 1) == 1

      updated = Deployments.get_deployment!(rollback.id)
      assert updated.status == :completed
    end

    test "caller-supplied source overrides the default rollback tag" do
      {app, _server} = setup_app_with_server()
      start_orchestrator(fn _n, s -> {:ok, s.version} end, fn _n, s -> {:ok, s.version} end)

      {:ok, _} =
        Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs(%{version: "1.0.0"}))

      assert_receive {:deployment_complete, _, :completed}, 1_000

      {:ok, _} =
        Orchestrator.trigger_deployment(
          Actor.system(),
          app,
          deploy_attrs(%{version: "2.0.0", artifact_url: "https://example.com/v2.tar.gz"})
        )

      assert_receive {:deployment_complete, _, :completed}, 1_000

      {:ok, rollback} =
        Orchestrator.trigger_rollback(Actor.system(), app, %{
          initiated_by: "test",
          source: "incident-42"
        })

      assert rollback.source == "incident-42"
      assert_receive {:deployment_complete, _, :completed}, 1_000
    end

    test "returns :no_rollback_target when there is no prior successful deployment" do
      {app, _server} = setup_app_with_server()
      start_orchestrator(fn _n, s -> {:ok, s.version} end, fn _n, s -> {:ok, s.version} end)

      assert {:error, :no_rollback_target} =
               Orchestrator.trigger_rollback(Actor.system(), app, %{initiated_by: "test"})
    end

    test "marks the rollback as failed and audits :rollback_failed when the agent errors" do
      {app, _server} = setup_app_with_server()

      deploy_caller = fn _n, spec -> {:ok, spec.version} end
      rollback_caller = fn _n, _spec -> {:error, "rollback agent crashed"} end

      start_orchestrator(deploy_caller, rollback_caller)

      {:ok, _} =
        Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs(%{version: "1.0.0"}))

      assert_receive {:deployment_complete, _, :completed}, 1_000

      {:ok, _} =
        Orchestrator.trigger_deployment(
          Actor.system(),
          app,
          deploy_attrs(%{version: "2.0.0", artifact_url: "https://example.com/v2.tar.gz"})
        )

      assert_receive {:deployment_complete, _, :completed}, 1_000

      capture_log(fn ->
        {:ok, rollback} =
          Orchestrator.trigger_rollback(Actor.system(), app, %{initiated_by: "test"})

        assert_receive {:deployment_complete, _, :failed}, 1_000

        assert Deployments.get_deployment!(rollback.id).status == :failed

        assert [event] = Still.Audit.list(type: :rollback_failed)
        assert event.subject_id == rollback.id
      end)
    end

    test "returns :no_rollback_target when only one successful deployment exists" do
      {app, _server} = setup_app_with_server()
      start_orchestrator(fn _n, s -> {:ok, s.version} end, fn _n, s -> {:ok, s.version} end)

      {:ok, _} =
        Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs(%{version: "1.0.0"}))

      assert_receive {:deployment_complete, _, :completed}, 1_000

      assert {:error, :no_rollback_target} =
               Orchestrator.trigger_rollback(Actor.system(), app, %{initiated_by: "test"})
    end

    test "rejects a rollback while another deployment is in progress" do
      {app, _server} = setup_app_with_server()
      test_pid = self()

      # Block the in-flight deployment so we can try a rollback while it's
      # still running.
      deploy_caller = fn _node, spec ->
        send(test_pid, {:waiting, self()})
        receive do: (:proceed -> {:ok, spec.version})
      end

      start_orchestrator(deploy_caller, fn _n, s -> {:ok, s.version} end)

      {:ok, _} =
        Orchestrator.trigger_deployment(Actor.system(), app, deploy_attrs(%{version: "1.0.0"}))

      assert_receive {:waiting, task_pid}, 1_000

      assert {:error, :deployment_in_progress} =
               Orchestrator.trigger_rollback(Actor.system(), app, %{initiated_by: "test"})

      send(task_pid, :proceed)
      assert_receive {:deployment_complete, _, :completed}, 1_000
    end
  end

  describe "reconcile_app_routes/1" do
    test "calls the route caller once per hosting server with a route spec" do
      {app, _server} = setup_app_with_server()
      start_orchestrator_with_route_caller(echo_route_caller())

      assert :ok = Orchestrator.reconcile_app_routes(app)

      assert_receive {:route_reconcile, :fake@host, spec}, 1_000
      assert spec.application == app.name
      assert spec.type == app.type
      assert spec.domain == app.domain
    end

    test "skips servers whose agent is disconnected" do
      app = application_fixture()
      server = server_fixture()
      {:ok, _as} = Applications.assign_server(Actor.system(), app, server)
      # No register_agent/1 — AgentConnectionManager has no node for it.
      start_orchestrator_with_route_caller(echo_route_caller())

      assert :ok = Orchestrator.reconcile_app_routes(app)
      refute_receive {:route_reconcile, _, _}, 300
    end
  end

  describe "update_application/3" do
    test "dispatches a route reconcile when the domain changes" do
      {app, _server} = setup_app_with_server()
      start_orchestrator_with_route_caller(echo_route_caller())

      assert {:ok, updated} =
               Orchestrator.update_application(Actor.system(), app, %{
                 "domain" => "changed.example.com"
               })

      assert updated.domain == "changed.example.com"

      assert_receive {:route_reconcile, :fake@host, spec}, 1_000
      assert spec.domain == "changed.example.com"
    end

    test "does not dispatch when no routing field changes" do
      {app, _server} = setup_app_with_server()
      start_orchestrator_with_route_caller(echo_route_caller())

      assert {:ok, _updated} =
               Orchestrator.update_application(Actor.system(), app, %{"min_healthy" => 2})

      refute_receive {:route_reconcile, _, _}, 300
    end

    test "dispatches a route reconcile carrying maintenance state when toggled" do
      {app, _server} = setup_app_with_server()
      start_orchestrator_with_route_caller(echo_route_caller())

      assert {:ok, updated} =
               Orchestrator.update_application(Actor.system(), app, %{
                 "maintenance" => true,
                 "maintenance_message" => "brb"
               })

      assert updated.maintenance == true

      assert_receive {:route_reconcile, :fake@host, spec}, 1_000
      assert spec.maintenance == true
      assert spec.maintenance_message == "brb"
    end

    test "dispatches a reconcile when maintenance is turned back off" do
      {app, _server} = setup_app_with_server()
      start_orchestrator_with_route_caller(echo_route_caller())

      # Park it first...
      assert {:ok, parked} =
               Orchestrator.update_application(Actor.system(), app, %{"maintenance" => true})

      assert_receive {:route_reconcile, _, %{maintenance: true}}, 1_000

      # ...then bring it back: the off transition must reconcile too, or the
      # app would stay stuck serving 503.
      assert {:ok, unparked} =
               Orchestrator.update_application(Actor.system(), parked, %{"maintenance" => false})

      assert unparked.maintenance == false

      assert_receive {:route_reconcile, :fake@host, spec}, 1_000
      assert spec.maintenance == false
    end
  end

  defp echo_route_caller do
    test_pid = self()

    fn node, spec ->
      send(test_pid, {:route_reconcile, node, spec})
      {:ok, :reconciled}
    end
  end

  defp start_orchestrator_with_route_caller(route_caller) do
    start_supervised!(
      {Orchestrator,
       agent_caller: fn _n, s -> {:ok, s.version} end,
       route_caller: route_caller,
       notifier: self()}
    )
  end
end
