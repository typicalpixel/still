defmodule StillWeb.WebhookControllerTest do
  use StillWeb.ConnCase, async: false

  alias Still.Accounts
  alias Still.AgentConnectionManager
  alias Still.Applications
  alias Still.Audit.Actor
  alias Still.Deployments
  alias Still.Orchestrator

  import Still.AccountsFixtures
  import Still.ApplicationsFixtures
  import Still.FleetFixtures

  setup %{conn: conn} do
    user = user_fixture()

    {:ok, api_key} =
      Accounts.create_api_key(Actor.system(), user, %{name: "test", permissions: ["admin"]})

    conn = put_req_header(conn, "authorization", "Bearer #{api_key.raw_key}")

    start_supervised!(AgentConnectionManager)

    start_supervised!(
      {Orchestrator,
       agent_caller: fn _n, s -> {:ok, s.version} end,
       artifact_stager: fn _app, _dep -> :ok end,
       notifier: self()}
    )

    %{conn: conn}
  end

  describe "POST /api/webhooks/deploy" do
    test "triggers a deployment from a webhook payload", %{conn: conn} do
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

      body =
        conn
        |> post("/api/webhooks/deploy", %{
          "application" => app.name,
          "version" => "1.0.0+abc",
          "artifact_url" => "https://example.com/app.tar.gz"
        })
        |> json_response(201)

      assert is_binary(body["data"]["deployment_id"])

      assert_receive {:deployment_complete, _, :completed}, 1_000
    end

    test "persists an optional source provenance string", %{conn: conn} do
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

      body =
        conn
        |> post("/api/webhooks/deploy", %{
          "application" => app.name,
          "version" => "1.0.0",
          "artifact_url" => "https://example.com/app.tar.gz",
          "source" => "ci:nightly-prod"
        })
        |> json_response(201)

      deployment = Deployments.get_deployment!(body["data"]["deployment_id"])
      assert deployment.source == "ci:nightly-prod"

      assert_receive {:deployment_complete, _, :completed}, 1_000
    end

    test "returns an error when the orchestrator rejects", %{conn: conn} do
      app = application_fixture()

      body =
        conn
        |> post("/api/webhooks/deploy", %{
          "application" => app.name,
          "version" => "1.0.0",
          "artifact_url" => "https://example.com/app.tar.gz"
        })
        |> json_response(409)

      assert body["error"]["message"] =~ "No servers"
    end

    test "returns 400 when application name is missing", %{conn: conn} do
      body =
        conn
        |> post("/api/webhooks/deploy", %{"version" => "1.0.0"})
        |> json_response(400)

      assert body["error"]["message"] =~ "Bad request"
    end
  end
end
