defmodule Still.DeploymentsTest do
  use Still.DataCase, async: false

  alias Still.Accounts.Scope
  alias Still.Applications
  alias Still.Audit
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Deployments.Deployment
  alias Still.Deployments.DeploymentStep

  import Still.AccountsFixtures
  import Still.ApplicationsFixtures
  import Still.DeploymentsFixtures
  import Still.FleetFixtures

  describe "create_deployment/2" do
    test "returns :no_servers_assigned when no servers are assigned" do
      app = application_fixture()

      assert {:error, :no_servers_assigned} =
               Deployments.create_deployment(Actor.system(), app, %{})
    end

    test "persists the deployment and one step per assigned server" do
      app = application_fixture()
      server1 = server_fixture()
      server2 = server_fixture()
      Applications.assign_server(Actor.system(), app, server1)
      Applications.assign_server(Actor.system(), app, server2)

      assert {:ok, %Deployment{} = deployment} =
               Deployments.create_deployment(Actor.system(), app, %{
                 version: "0.0.1+abc",
                 artifact_url: "https://example.com/app.tar.gz",
                 initiated_by: "user:test"
               })

      assert deployment.id
      assert deployment.application_id == app.id
      assert deployment.version == "0.0.1+abc"
      assert deployment.status == :pending
      assert is_nil(deployment.started_at)
      assert is_nil(deployment.completed_at)

      assert length(deployment.steps) == 2
      step_server_ids = deployment.steps |> Enum.map(& &1.server_id) |> Enum.sort()
      assert step_server_ids == Enum.sort([server1.id, server2.id])
      assert Enum.all?(deployment.steps, &(&1.status == :pending))
    end

    test "returns an error changeset for invalid attributes" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)

      assert {:error, changeset} = Deployments.create_deployment(Actor.system(), app, %{})
      errors = errors_on(changeset)
      assert errors[:version]
      assert errors[:artifact_url]
      assert errors[:initiated_by]
    end

    test "rolls back the entire transaction on failure" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)

      assert {:error, _changeset} = Deployments.create_deployment(Actor.system(), app, %{})

      assert [] == Deployments.list_deployments(application: app.name)
    end
  end

  describe "list_deployments/1" do
    test "returns deployments newest first" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)

      d1 = deployment_fixture(app)
      d2 = deployment_fixture(app)
      d3 = deployment_fixture(app)

      ids = Deployments.list_deployments() |> Enum.map(& &1.id)
      assert ids == [d3.id, d2.id, d1.id]
    end

    test "filters to a single application by name" do
      app1 = application_fixture()
      app2 = application_fixture()
      server = server_fixture()
      other_server = server_fixture()
      Applications.assign_server(Actor.system(), app1, server)
      Applications.assign_server(Actor.system(), app2, other_server)

      d1 = deployment_fixture(app1)
      _d2 = deployment_fixture(app2)

      assert [returned] = Deployments.list_deployments(application: app1.name)
      assert returned.id == d1.id
    end

    test "filters to deployments touching a specific server" do
      app_a = application_fixture()
      app_b = application_fixture()
      server_a = server_fixture()
      server_b = server_fixture()
      Applications.assign_server(Actor.system(), app_a, server_a)
      Applications.assign_server(Actor.system(), app_b, server_b)

      d_a = deployment_fixture(app_a)
      d_b = deployment_fixture(app_b)

      assert [only_a] = Deployments.list_deployments(server: server_a.id)
      assert only_a.id == d_a.id

      assert [only_b] = Deployments.list_deployments(server: server_b.id)
      assert only_b.id == d_b.id
    end

    test "filters by status" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      d1 = deployment_fixture(app)
      d2 = deployment_fixture(app)

      Deployments.complete_deployment!(d2)

      assert [completed] = Deployments.list_deployments(status: "completed")
      assert completed.id == d2.id

      assert [pending] = Deployments.list_deployments(status: :pending)
      assert pending.id == d1.id
    end

    test "limit caps the result count" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      _ = Enum.map(1..5, fn _ -> deployment_fixture(app) end)

      assert 2 == length(Deployments.list_deployments(limit: 2))
    end

    test "limit accepts a string (controller params are strings)" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      _ = Enum.map(1..3, fn _ -> deployment_fixture(app) end)

      assert 2 == length(Deployments.list_deployments(%{"limit" => "2"}))
    end

    test "limit falls back to default for unparseable input" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      _ = deployment_fixture(app)

      # Strings that don't parse, and non-integer/non-binary inputs, fall
      # through to the default limit (50) without raising.
      assert [_] = Deployments.list_deployments(%{"limit" => "not-a-number"})
      assert [_] = Deployments.list_deployments(limit: :weird)
    end

    test "filters by initiated_by" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)

      mine = deployment_fixture(app, %{initiated_by: "user:alice"})
      _theirs = deployment_fixture(app, %{initiated_by: "user:bob"})

      assert [row] = Deployments.list_deployments(initiated_by: "user:alice")
      assert row.id == mine.id
    end

    test "filters by before (keyset pagination)" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)

      older = deployment_fixture(app)
      _newer = deployment_fixture(app)

      cutoff = DateTime.add(older.inserted_at, 1, :microsecond)
      assert [only] = Deployments.list_deployments(before: DateTime.to_iso8601(cutoff))
      assert only.id == older.id
    end

    test "ignores a before filter with a malformed timestamp" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      _ = deployment_fixture(app)

      # Unparseable ISO string → filter is a no-op rather than an error.
      assert [_] = Deployments.list_deployments(before: "not-a-timestamp")
    end

    test "ignores an unknown status string" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      _ = deployment_fixture(app)

      assert [_] = Deployments.list_deployments(status: "bogus")
    end

    test "accepts string-keyed filters (controller params pass-through)" do
      app = application_fixture(%{name: "str-keys"})
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      d = deployment_fixture(app)

      assert [row] = Deployments.list_deployments(%{"application" => "str-keys"})
      assert row.id == d.id
    end

    test "returns an empty list when no deployments exist" do
      assert [] == Deployments.list_deployments()
    end

    test "preloads the application for each row" do
      app = application_fixture(%{name: "my-api"})
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      _ = deployment_fixture(app)

      assert [row] = Deployments.list_deployments()
      assert row.application.name == "my-api"
    end
  end

  describe "get_deployment!/1" do
    test "returns the deployment with steps preloaded" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app)

      loaded = Deployments.get_deployment!(deployment.id)
      assert loaded.id == deployment.id
      assert is_list(loaded.steps)
      assert length(loaded.steps) == 1
    end

    test "raises Ecto.NoResultsError when the id is unknown" do
      assert_raise Ecto.NoResultsError, fn ->
        Deployments.get_deployment!(Ecto.UUID.generate())
      end
    end

    test "preloads steps in execution order (started_at asc, nulls last)" do
      import Ecto.Query
      app = application_fixture()
      Applications.assign_server(Actor.system(), app, server_fixture())
      Applications.assign_server(Actor.system(), app, server_fixture())
      Applications.assign_server(Actor.system(), app, server_fixture())
      deployment = deployment_fixture(app)
      [s1, s2, s3] = Deployments.list_deployment_steps_for(deployment)

      # server2 ran first, server1 ran second, server3 never started
      now = DateTime.utc_now()

      from(s in Still.Deployments.DeploymentStep, where: s.id == ^s2.id)
      |> Still.Repo.update_all(set: [started_at: DateTime.add(now, -200, :millisecond)])

      from(s in Still.Deployments.DeploymentStep, where: s.id == ^s1.id)
      |> Still.Repo.update_all(set: [started_at: DateTime.add(now, -100, :millisecond)])

      loaded = Deployments.get_deployment!(deployment.id)
      assert Enum.map(loaded.steps, & &1.id) == [s2.id, s1.id, s3.id]
    end
  end

  describe "list_deployment_steps_for/1" do
    test "returns the steps for the given deployment" do
      app = application_fixture()
      server1 = server_fixture()
      server2 = server_fixture()
      Applications.assign_server(Actor.system(), app, server1)
      Applications.assign_server(Actor.system(), app, server2)
      deployment = deployment_fixture(app)

      steps = Deployments.list_deployment_steps_for(deployment)
      assert length(steps) == 2
      assert Enum.all?(steps, &(&1.deployment_id == deployment.id))
    end
  end

  describe "get_deployment_step!/1" do
    test "returns the step when it exists" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app)
      [step] = Deployments.list_deployment_steps_for(deployment)

      assert %DeploymentStep{id: id} = Deployments.get_deployment_step!(step.id)
      assert id == step.id
    end

    test "raises Ecto.NoResultsError when the id is unknown" do
      assert_raise Ecto.NoResultsError, fn ->
        Deployments.get_deployment_step!(Ecto.UUID.generate())
      end
    end
  end

  describe "deployment status mutations" do
    setup do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app)
      %{deployment: deployment, server: server}
    end

    test "start_deployment!/1 sets status to :in_progress with started_at",
         %{deployment: deployment} do
      updated = Deployments.start_deployment!(deployment)
      assert updated.status == :in_progress
      assert %DateTime{} = updated.started_at
    end

    test "complete_deployment!/1 sets status to :completed with completed_at",
         %{deployment: deployment} do
      updated =
        deployment |> Deployments.start_deployment!() |> Deployments.complete_deployment!()

      assert updated.status == :completed
      assert %DateTime{} = updated.completed_at
    end

    test "fail_deployment!/1 sets status to :failed with completed_at",
         %{deployment: deployment} do
      updated = deployment |> Deployments.start_deployment!() |> Deployments.fail_deployment!()
      assert updated.status == :failed
      assert %DateTime{} = updated.completed_at
    end
  end

  describe "mark_orphaned_as_failed!/1" do
    test "flips every in_progress deployment to failed with a completed_at" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      d1 = deployment_fixture(app) |> Deployments.start_deployment!()
      d2 = deployment_fixture(app) |> Deployments.start_deployment!()

      assert {2, _} = Deployments.mark_orphaned_as_failed!("controller_restart")

      for d <- [d1, d2] do
        reloaded = Deployments.get_deployment!(d.id)
        assert reloaded.status == :failed
        assert %DateTime{} = reloaded.completed_at
      end
    end

    test "marks non-terminal steps as failed with the given reason" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app) |> Deployments.start_deployment!()
      [step] = Deployments.list_deployment_steps_for(deployment)
      Deployments.start_deployment_step!(step)

      assert {1, 1} = Deployments.mark_orphaned_as_failed!("controller_restart")

      reloaded = Deployments.get_deployment_step!(step.id)
      assert reloaded.status == :failed
      assert reloaded.error == "controller_restart"
      assert %DateTime{} = reloaded.completed_at
    end

    test "leaves already-completed and already-failed steps alone" do
      app = application_fixture()
      server1 = server_fixture()
      server2 = server_fixture()
      Applications.assign_server(Actor.system(), app, server1)
      Applications.assign_server(Actor.system(), app, server2)
      deployment = deployment_fixture(app) |> Deployments.start_deployment!()
      [s1, s2] = Deployments.list_deployment_steps_for(deployment)

      completed =
        Deployments.start_deployment_step!(s1) |> Deployments.complete_deployment_step!()

      failed_existing = Deployments.fail_deployment_step!(s2, "earlier_error")

      Deployments.mark_orphaned_as_failed!("controller_restart")

      assert Deployments.get_deployment_step!(completed.id).status == :completed
      unchanged = Deployments.get_deployment_step!(failed_existing.id)
      assert unchanged.status == :failed
      assert unchanged.error == "earlier_error"
    end

    test "ignores deployments that are not in_progress" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      pending = deployment_fixture(app)

      completed =
        deployment_fixture(app)
        |> Deployments.start_deployment!()
        |> Deployments.complete_deployment!()

      assert {0, 0} = Deployments.mark_orphaned_as_failed!("controller_restart")
      assert Deployments.get_deployment!(pending.id).status == :pending
      assert Deployments.get_deployment!(completed.id).status == :completed
    end
  end

  describe "deployment step status mutations" do
    setup do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app)
      [step] = Deployments.list_deployment_steps_for(deployment)
      %{step: step}
    end

    test "start_deployment_step!/1 stamps started_at without changing status", %{step: step} do
      assert step.status == :pending
      assert is_nil(step.started_at)

      updated = Deployments.start_deployment_step!(step)
      assert %DateTime{} = updated.started_at
      assert updated.status == :pending
    end

    test "complete_deployment_step!/1 marks the step as completed", %{step: step} do
      updated = Deployments.complete_deployment_step!(step)
      assert updated.status == :completed
      assert %DateTime{} = updated.completed_at
    end

    test "fail_deployment_step!/2 marks the step as failed with error", %{step: step} do
      updated = Deployments.fail_deployment_step!(step, "health check timeout")
      assert updated.status == :failed
      assert updated.error == "health check timeout"
      assert %DateTime{} = updated.completed_at
    end
  end

  describe "put_step_log/3" do
    setup do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app)
      %{deployment: deployment, server: server}
    end

    test "writes the log onto the matching step", %{deployment: deployment, server: server} do
      assert {:ok, step} = Deployments.put_step_log(deployment.id, server.id, "boot log")
      assert step.log == "boot log"
      assert Deployments.get_deployment_step!(step.id).log == "boot log"
    end

    test "returns :error when no step matches", %{server: server} do
      assert Deployments.put_step_log(Ecto.UUID.generate(), server.id, "x") == :error
    end
  end

  describe "deployment_status/1" do
    test "returns the status atom, or nil for an unknown id" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app)

      assert Deployments.deployment_status(deployment.id) == :pending

      Deployments.fail_deployment!(deployment, "x")
      assert Deployments.deployment_status(deployment.id) == :failed

      assert Deployments.deployment_status(Ecto.UUID.generate()) == nil
    end
  end

  describe "get_step_for_server!/2" do
    test "returns the step matching the deployment and server" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app)

      step = Deployments.get_step_for_server!(deployment.id, server.id)
      assert step.deployment_id == deployment.id
      assert step.server_id == server.id
    end

    test "raises when no matching step exists" do
      assert_raise Ecto.NoResultsError, fn ->
        Deployments.get_step_for_server!(Ecto.UUID.generate(), Ecto.UUID.generate())
      end
    end
  end

  describe "eta_at/1" do
    test "returns nil for terminal deployments" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app)
      completed = Deployments.complete_deployment!(deployment)

      assert Deployments.eta_at(completed) == nil
      assert Deployments.eta_at(%{completed | status: :failed}) == nil
      assert Deployments.eta_at(%{completed | status: :rolled_back}) == nil
    end

    test "returns nil when no history exists to estimate from" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)

      deployment = deployment_fixture(app)
      assert Deployments.eta_at(deployment) == nil
    end

    test "estimates completion from recent successful deploy history" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)

      # Seed one completed deploy whose single step took 10 seconds.
      seed_completed_deploy(app, server, 10_000)

      # The in-flight deploy has one pending step.
      in_flight = deployment_fixture(app)
      eta = Deployments.eta_at(in_flight)

      assert %DateTime{} = eta
      # Should land ~10 seconds from now — allow a generous window.
      diff_ms = DateTime.diff(eta, DateTime.utc_now(), :millisecond)
      assert diff_ms > 5_000
      assert diff_ms < 15_000
    end

    test "returns a zero-offset ETA when all steps are already complete" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)

      seed_completed_deploy(app, server, 10_000)

      # In-flight deploy with every step completed — remaining = 0.
      in_flight = deployment_fixture(app)
      [step] = Deployments.list_deployment_steps_for(in_flight)
      Deployments.complete_deployment_step!(step)

      # Reload with fresh steps.
      reloaded = Deployments.get_deployment!(in_flight.id)
      eta = Deployments.eta_at(reloaded)

      diff_ms = DateTime.diff(eta, DateTime.utc_now(), :millisecond)
      assert abs(diff_ms) < 500
    end
  end

  describe "progress_and_eta_for/1" do
    test "returns a map with progress and eta_at" do
      app = application_fixture()
      server = server_fixture()
      Applications.assign_server(Actor.system(), app, server)
      deployment = deployment_fixture(app)

      assert %{progress: %{completed_steps: 0, total_steps: 1, pct: 0}, eta_at: nil} =
               Deployments.progress_and_eta_for(deployment.id)
    end
  end

  # Inserts a completed deploy whose step took `duration_ms` to run —
  # used to seed the history the ETA helper averages over.
  defp seed_completed_deploy(app, server, duration_ms) do
    deployment = deployment_fixture(app)
    [step] = Deployments.list_deployment_steps_for(deployment)

    started = DateTime.add(DateTime.utc_now(), -duration_ms * 2, :millisecond)
    completed = DateTime.add(started, duration_ms, :millisecond)

    step
    |> Ecto.Changeset.change(%{
      status: :completed,
      started_at: started,
      completed_at: completed
    })
    |> Still.Repo.update!()

    deployment
    |> Ecto.Changeset.change(%{status: :completed, completed_at: completed})
    |> Still.Repo.update!()

    {deployment, server}
  end

  describe "audit trail" do
    setup do
      app = application_fixture(%{name: "audited-app"})
      server = server_fixture(%{name: "edge-1"})
      {:ok, _} = Applications.assign_server(Actor.system(), app, server)

      operator = user_fixture(%{email: "deployer@example.com"})
      actor = Actor.from_scope(Scope.for_user(operator))

      %{app: app, actor: actor}
    end

    test "create_deployment records :deploy_initiated with after-snapshot for a regular deploy",
         %{app: app, actor: actor} do
      {:ok, deployment} =
        Deployments.create_deployment(actor, app, %{
          version: "1.0.0",
          artifact_url: "https://example.com/v1.tar.gz",
          initiated_by: "user:deployer@example.com"
        })

      assert [event] = Audit.list(type: :deploy_initiated)
      assert event.subject_type == "deployment"
      assert event.subject_id == deployment.id
      assert event.actor_label == "deployer@example.com"
      assert event.payload["application_name"] == "audited-app"
      assert event.payload["version"] == "1.0.0"
      assert event.before == nil
      assert event.after["version"] == "1.0.0"
    end

    test "create_deployment uses :rollback_initiated when source is \"rollback\"",
         %{app: app, actor: actor} do
      {:ok, deployment} =
        Deployments.create_deployment(actor, app, %{
          version: "0.9.0",
          artifact_url: "https://example.com/v0.9.tar.gz",
          source: "rollback",
          initiated_by: "user:deployer@example.com"
        })

      assert Audit.list(type: :deploy_initiated) == []
      assert [event] = Audit.list(type: :rollback_initiated)
      assert event.subject_id == deployment.id
      assert event.payload["source"] == "rollback"
    end

    test "failed mutation does not write an audit row", %{app: app, actor: actor} do
      audit_count_before = length(Audit.list(type: :deploy_initiated))

      assert {:error, %Ecto.Changeset{}} = Deployments.create_deployment(actor, app, %{})

      assert length(Audit.list(type: :deploy_initiated)) == audit_count_before
    end
  end

  describe "get_rollback_target/1" do
    setup do
      app = application_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app, server_fixture())
      {:ok, app: app}
    end

    test "returns the previous completed deployment", %{app: app} do
      seed_completed(app, "1.0.0", nil, ~U[2026-01-01 00:00:00.000000Z])
      seed_completed(app, "2.0.0", nil, ~U[2026-01-01 00:01:00.000000Z])

      assert %Deployment{version: "1.0.0"} = Deployments.get_rollback_target(app)
    end

    test "returns nil with fewer than two completed deployments", %{app: app} do
      seed_completed(app, "1.0.0", nil, ~U[2026-01-01 00:00:00.000000Z])

      assert Deployments.get_rollback_target(app) == nil
    end

    test "returns nil when the current live deployment is itself a rollback (no bounce)",
         %{app: app} do
      seed_completed(app, "1.0.0", nil, ~U[2026-01-01 00:00:00.000000Z])
      seed_completed(app, "2.0.0", nil, ~U[2026-01-01 00:01:00.000000Z])
      # A rollback to 1.0.0 is recorded as a completed deployment, source "rollback".
      seed_completed(app, "1.0.0", "rollback", ~U[2026-01-01 00:02:00.000000Z])

      assert Deployments.get_rollback_target(app) == nil
    end

    test "after a rollback and a new forward deploy, has a target again", %{app: app} do
      seed_completed(app, "1.0.0", nil, ~U[2026-01-01 00:00:00.000000Z])
      seed_completed(app, "2.0.0", nil, ~U[2026-01-01 00:01:00.000000Z])
      seed_completed(app, "1.0.0", "rollback", ~U[2026-01-01 00:02:00.000000Z])
      seed_completed(app, "3.0.0", nil, ~U[2026-01-01 00:03:00.000000Z])

      # Most recent is forward 3.0.0; its predecessor put 1.0.0 live.
      assert %Deployment{version: "1.0.0"} = Deployments.get_rollback_target(app)
    end
  end

  defp seed_completed(app, version, source, completed_at) do
    app
    |> deployment_fixture(%{version: version, source: source})
    |> Ecto.Changeset.change(%{status: :completed, completed_at: completed_at})
    |> Still.Repo.update!()
  end
end
