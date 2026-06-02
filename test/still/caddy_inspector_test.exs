defmodule Still.CaddyInspectorTest do
  use Still.DataCase, async: false

  alias Still.AgentConnectionManager
  alias Still.CaddyInspector

  describe "local_config/0" do
    test "returns {:ok, config} when Caddy's admin API responds" do
      config = %{"apps" => %{"http" => %{"servers" => %{"still" => %{}}}}}
      Req.Test.stub(Still.Agent.CaddyManager, fn conn -> Req.Test.json(conn, config) end)

      assert {:ok, ^config} = CaddyInspector.local_config()
    end

    test "normalizes a Caddy admin-API error to :caddy_unreachable" do
      Req.Test.stub(Still.Agent.CaddyManager, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
      end)

      assert {:error, :caddy_unreachable} = CaddyInspector.local_config()
    end
  end

  describe "config_for_server/1" do
    setup do
      # Non-async DataCase runs the sandbox in shared mode, so this process's
      # connection is visible to the AgentConnectionManager process too.
      start_supervised!(AgentConnectionManager)
      :ok
    end

    test "returns :agent_disconnected when no agent is registered for the id" do
      id = "missing-#{System.unique_integer([:positive])}"
      assert {:error, :agent_disconnected} = CaddyInspector.config_for_server(id)
    end

    test "returns :caddy_unreachable when the agent's node can't be reached" do
      id = "fake-#{System.unique_integer([:positive])}"

      AgentConnectionManager.agent_connected(%{
        server_id: id,
        node: :fake@nohost,
        connected_at: DateTime.utc_now(),
        applications: []
      })

      # Flush the async cast so the ETS entry is in place before we read it.
      :sys.get_state(AgentConnectionManager)

      assert {:error, :caddy_unreachable} = CaddyInspector.config_for_server(id)
    end
  end
end
