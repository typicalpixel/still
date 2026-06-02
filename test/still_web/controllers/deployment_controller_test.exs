defmodule StillWeb.DeploymentControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Orchestrator

  import Still.AccountsFixtures
  import Still.ApplicationsFixtures
  import Still.DeploymentsFixtures
  import Still.FleetFixtures

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, api_key} =
      Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["admin"]})

    conn = put_req_header(conn, "authorization", "Bearer #{api_key.raw_key}")

    acm = start_supervised!(AgentConnectionManager)

    orch =
      start_supervised!(
        {Orchestrator,
         agent_caller: fn _n, s -> {:ok, s.version} end,
         rollback_agent_caller: fn _n, s -> {:ok, s.version} end,
         artifact_stager: fn _app, _dep -> :ok end,
         notifier: self()}
      )

    %{conn: conn, user: user, acm: acm, orch: orch}
  end

  defp setup_deployable_app do
    app = application_fixture()
    server = server_fixture()
    {:ok, _} = Applications.assign_server(Actor.system(), app, server)

    AgentConnectionManager.agent_connected(%{
      server_id: server.id,
      node: :fake@host,
      connected_at: DateTime.utc_now(),
      applications: []
    })

    :sys.get_state(AgentConnectionManager)

    {app, server}
  end

  describe "POST /api/applications/:name/deployments" do
    test "triggers a deployment", %{conn: conn} do
      {app, _server} = setup_deployable_app()

      body =
        conn
        |> post("/api/applications/#{app.name}/deployments", %{
          "version" => "1.0.0+abc",
          "artifact_url" => "https://example.com/app.tar.gz"
        })
        |> json_response(201)

      assert body["data"]["version"] == "1.0.0+abc"
      assert body["data"]["status"] == "pending"
      assert body["data"]["source"] == nil

      assert_receive {:deployment_complete, _, :completed}, 1_000
    end

    test "persists an optional source provenance string", %{conn: conn} do
      {app, _server} = setup_deployable_app()

      body =
        conn
        |> post("/api/applications/#{app.name}/deployments", %{
          "version" => "1.0.0",
          "artifact_url" => "https://example.com/app.tar.gz",
          "source" => "git:main@abc1234"
        })
        |> json_response(201)

      assert body["data"]["source"] == "git:main@abc1234"

      assert_receive {:deployment_complete, _, :completed}, 1_000
    end

    test "returns 409 when no servers are assigned", %{conn: conn} do
      app = application_fixture()

      body =
        conn
        |> post("/api/applications/#{app.name}/deployments", %{
          "version" => "1.0.0",
          "artifact_url" => "https://example.com/app.tar.gz"
        })
        |> json_response(409)

      assert body["error"]["message"] =~ "No servers"
    end
  end

  describe "GET /api/deployments" do
    test "lists deployments newest first with application name included", %{conn: conn} do
      {app, _server} = setup_deployable_app()
      older = deployment_fixture(app, %{version: "1.0.0"})
      newer = deployment_fixture(app, %{version: "2.0.0"})

      body =
        conn
        |> get("/api/deployments")
        |> json_response(200)

      assert [
               %{"id" => newer_id, "version" => "2.0.0", "application_name" => newer_app_name},
               %{"id" => older_id, "version" => "1.0.0", "application_name" => older_app_name}
             ] = body["data"]

      assert newer_id == newer.id
      assert older_id == older.id
      assert newer_app_name == app.name
      assert older_app_name == app.name
    end

    test "filters by application name", %{conn: conn} do
      {app_a, _} = setup_deployable_app()
      app_b = application_fixture(%{name: "other"})
      server_b = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app_b, server_b)

      _ = deployment_fixture(app_a, %{version: "1.0.0"})
      keeper = deployment_fixture(app_b, %{version: "3.0.0"})

      body =
        conn
        |> get("/api/deployments?application=#{app_b.name}")
        |> json_response(200)

      assert [%{"id" => id}] = body["data"]
      assert id == keeper.id
    end

    test "filters by server id", %{conn: conn} do
      {app_a, server_a} = setup_deployable_app()
      app_b = application_fixture(%{name: "other"})
      server_b = server_fixture()
      {:ok, _} = Applications.assign_server(Actor.system(), app_b, server_b)

      mine = deployment_fixture(app_a, %{version: "1.0.0"})
      _theirs = deployment_fixture(app_b, %{version: "1.0.0"})

      body =
        conn
        |> get("/api/deployments?server=#{server_a.id}")
        |> json_response(200)

      assert [%{"id" => id}] = body["data"]
      assert id == mine.id
    end

    test "filters by status", %{conn: conn} do
      {app, _server} = setup_deployable_app()
      d1 = deployment_fixture(app)
      d2 = deployment_fixture(app)
      Still.Deployments.complete_deployment!(d2)

      body =
        conn
        |> get("/api/deployments?status=completed")
        |> json_response(200)

      assert [%{"id" => id}] = body["data"]
      assert id == d2.id
      refute id == d1.id
    end

    test "includes duration_ms in each row (null until completed)", %{conn: conn} do
      {app, _server} = setup_deployable_app()
      pending = deployment_fixture(app, %{version: "1.0.0"})

      # Completed deployment with synthetic start/completion timestamps.
      completed = deployment_fixture(app, %{version: "2.0.0"})
      started = DateTime.utc_now()
      finished = DateTime.add(started, 1_500, :millisecond)

      completed
      |> Ecto.Changeset.change(%{
        status: :completed,
        started_at: started,
        completed_at: finished
      })
      |> Still.Repo.update!()

      body = conn |> get("/api/deployments") |> json_response(200)

      by_id = Map.new(body["data"], &{&1["id"], &1})
      assert by_id[pending.id]["duration_ms"] == nil
      assert by_id[completed.id]["duration_ms"] == 1_500
    end

    test "respects limit", %{conn: conn} do
      {app, _server} = setup_deployable_app()
      _ = Enum.map(1..4, fn _ -> deployment_fixture(app) end)

      body =
        conn
        |> get("/api/deployments?limit=2")
        |> json_response(200)

      assert 2 == length(body["data"])
    end
  end

  describe "GET /api/deployments/:id" do
    test "shows a deployment with a step per assigned server", %{conn: conn} do
      {app, server} = setup_deployable_app()
      deployment = deployment_fixture(app)

      body =
        conn
        |> get("/api/deployments/#{deployment.id}")
        |> json_response(200)

      assert body["data"]["id"] == deployment.id
      assert body["data"]["version"] == deployment.version

      assert [%{"server_id" => step_server_id, "status" => "pending"}] = body["data"]["steps"]
      assert step_server_id == server.id
    end

    test "returns 404 for an unknown deployment id", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, "/api/deployments/#{Ecto.UUID.generate()}")
      end
    end
  end

  describe "authorization" do
    setup %{conn: conn} do
      # Override the per-test conn with a read-only API key on a viewer
      # user so we can exercise the 403 path. The describe's own setup
      # already attached an admin key — shadowing it here.
      user = user_fixture()

      {:ok, api_key} =
        Accounts.create_api_key(Actor.system(), user, %{name: "read-only", permissions: ["read"]})

      %{conn: put_req_header(conn, "authorization", "Bearer #{api_key.raw_key}")}
    end

    test "GET /api/deployments allows a read-only key", %{conn: conn} do
      {_app, _server} = setup_deployable_app()

      assert %{"data" => _} =
               conn
               |> get("/api/deployments")
               |> json_response(200)
    end

    test "POST /api/applications/:name/deployments rejects a read-only key with 403", %{
      conn: conn
    } do
      {app, _server} = setup_deployable_app()

      body =
        conn
        |> post("/api/applications/#{app.name}/deployments", %{
          "version" => "1.0.0",
          "artifact_url" => "https://example.com/app.tar.gz"
        })
        |> json_response(403)

      assert body["error"]["message"] == "Insufficient permissions"
      assert body["error"]["detail"]["required"] == "deploy"
    end

    test "POST /api/applications/:name/rollback rejects a read-only key with 403", %{conn: conn} do
      {app, _server} = setup_deployable_app()

      body =
        conn
        |> post("/api/applications/#{app.name}/rollback")
        |> json_response(403)

      assert body["error"]["detail"]["required"] == "rollback"
    end
  end

  describe "POST /api/applications/:name/rollback" do
    test "returns 409 when the application has no rollback target", %{conn: conn} do
      {app, _server} = setup_deployable_app()

      body =
        conn
        |> post("/api/applications/#{app.name}/rollback")
        |> json_response(409)

      assert body["error"]["message"] =~ "No previous successful deployment"
    end

    test "rolls back to the previous successful deployment", %{conn: conn} do
      {app, _server} = setup_deployable_app()

      conn
      |> post("/api/applications/#{app.name}/deployments", %{
        "version" => "1.0.0",
        "artifact_url" => "https://example.com/v1.tar.gz"
      })
      |> json_response(201)

      assert_receive {:deployment_complete, _, :completed}, 1_000

      conn
      |> post("/api/applications/#{app.name}/deployments", %{
        "version" => "2.0.0",
        "artifact_url" => "https://example.com/v2.tar.gz"
      })
      |> json_response(201)

      assert_receive {:deployment_complete, _, :completed}, 1_000

      body =
        conn
        |> post("/api/applications/#{app.name}/rollback")
        |> json_response(202)

      # A rollback recreates a deployment row stamped with the previous version,
      # so the response echoes the rollback target.
      assert body["data"]["version"] == "1.0.0"
      assert body["data"]["artifact_url"] == "https://example.com/v1.tar.gz"

      assert_receive {:deployment_complete, _, :completed}, 1_000
    end
  end
end
