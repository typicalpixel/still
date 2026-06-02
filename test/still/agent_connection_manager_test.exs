defmodule Still.AgentConnectionManagerTest do
  use Still.DataCase, async: false

  alias Still.AgentConnectionManager
  alias Still.Fleet

  import Still.FleetFixtures

  setup do
    start_supervised!(AgentConnectionManager)
    :ok
  end

  defp sample_report(server_id) do
    %{
      server_id: server_id,
      node: :"still_agent@10.0.0.3",
      connected_at: DateTime.utc_now(),
      applications: [
        %{
          application_name: "my-api",
          active_slot: :blue,
          active_port: 20_000,
          current_version: "0.0.1+abc",
          previous_version: nil,
          health: :healthy,
          last_health_check: DateTime.utc_now()
        }
      ]
    }
  end

  describe "persisting agent announcements" do
    test "writes system_info to servers.metadata and stamps last_seen_at" do
      server = server_fixture()
      connected_at = DateTime.utc_now()

      report = %{
        server_id: server.id,
        node: :"still_agent@10.0.0.5",
        connected_at: connected_at,
        system_info: %{hostname: "bm-fra-01", cpu_count: 8, memory_mb: 16_384},
        applications: []
      }

      AgentConnectionManager.agent_connected(report)
      :sys.get_state(AgentConnectionManager)

      reloaded = Fleet.get_server!(server.id)
      assert reloaded.metadata["hostname"] == "bm-fra-01"
      assert reloaded.metadata["cpu_count"] == 8
      assert DateTime.compare(reloaded.last_seen_at, connected_at) == :eq
    end

    test "tolerates reports that omit system_info" do
      server = server_fixture()

      report = %{
        server_id: server.id,
        node: :"still_agent@10.0.0.6",
        connected_at: DateTime.utc_now(),
        applications: []
      }

      AgentConnectionManager.agent_connected(report)
      :sys.get_state(AgentConnectionManager)

      # ETS still gets the report even with no system_info.
      assert AgentConnectionManager.connected?(server.id)
    end
  end

  describe "agent_connected/1 + get_agent_state/1" do
    test "stores the agent report and makes it queryable" do
      report = sample_report("srv-1")
      AgentConnectionManager.agent_connected(report)

      # Give the cast time to process
      :sys.get_state(AgentConnectionManager)

      result = AgentConnectionManager.get_agent_state("srv-1")
      assert result.server_id == "srv-1"
      assert result.node == :"still_agent@10.0.0.3"
      assert length(result.applications) == 1
    end

    test "overwrites the previous report on reconnect" do
      AgentConnectionManager.agent_connected(sample_report("srv-1"))
      :sys.get_state(AgentConnectionManager)

      updated = %{sample_report("srv-1") | applications: []}
      AgentConnectionManager.agent_connected(updated)
      :sys.get_state(AgentConnectionManager)

      assert AgentConnectionManager.get_agent_state("srv-1").applications == []
    end
  end

  describe "agent_disconnected/1" do
    @tag :capture_log
    test "removes the agent from the table" do
      AgentConnectionManager.agent_connected(sample_report("srv-1"))
      :sys.get_state(AgentConnectionManager)
      assert AgentConnectionManager.connected?("srv-1")

      AgentConnectionManager.agent_disconnected("srv-1")
      :sys.get_state(AgentConnectionManager)

      refute AgentConnectionManager.connected?("srv-1")
      assert is_nil(AgentConnectionManager.get_agent_state("srv-1"))
    end
  end

  describe "update_application_state/3" do
    @tag :capture_log
    test "merges the new app state into the existing report" do
      AgentConnectionManager.agent_connected(sample_report("srv-1"))
      :sys.get_state(AgentConnectionManager)

      AgentConnectionManager.update_application_state("srv-1", "my-api", %{
        health: :unhealthy,
        current_version: "0.0.2+def"
      })

      :sys.get_state(AgentConnectionManager)

      report = AgentConnectionManager.get_agent_state("srv-1")
      [app] = report.applications
      assert app.health == :unhealthy
      assert app.current_version == "0.0.2+def"
      # Unchanged fields are preserved
      assert app.active_slot == :blue
    end

    @tag :capture_log
    test "ignores updates for unknown agents" do
      AgentConnectionManager.update_application_state("ghost", "my-api", %{health: :unhealthy})
      :sys.get_state(AgentConnectionManager)

      assert is_nil(AgentConnectionManager.get_agent_state("ghost"))
    end

    @tag :capture_log
    test "adds a new application entry when the agent hasn't reported it before" do
      # The agent may announce with an empty applications list (fresh box
      # with no state.json files) and only report the first app after a
      # successful initial deploy. The ETS view has to reflect that new
      # app — merging has to upsert, not just update-in-place.
      AgentConnectionManager.agent_connected(%{
        server_id: "srv-fresh",
        node: :"still_agent@10.0.0.4",
        connected_at: DateTime.utc_now(),
        applications: []
      })

      :sys.get_state(AgentConnectionManager)

      AgentConnectionManager.update_application_state("srv-fresh", "first-app", %{
        current_version: "1.0.0",
        active_slot: "blue",
        health: :healthy
      })

      :sys.get_state(AgentConnectionManager)

      assert %{applications: [app]} = AgentConnectionManager.get_agent_state("srv-fresh")
      assert app.application_name == "first-app"
      assert app.current_version == "1.0.0"
      assert app.active_slot == "blue"
      assert app.health == :healthy
    end
  end

  describe "list_agents/0" do
    @tag :capture_log
    test "returns all connected agent reports" do
      AgentConnectionManager.agent_connected(sample_report("srv-1"))
      AgentConnectionManager.agent_connected(sample_report("srv-2"))
      :sys.get_state(AgentConnectionManager)

      agents = AgentConnectionManager.list_agents()
      ids = Enum.map(agents, & &1.server_id) |> Enum.sort()
      assert ids == ["srv-1", "srv-2"]
    end

    test "returns an empty list when no agents are connected" do
      assert [] == AgentConnectionManager.list_agents()
    end
  end

  describe "connected?/1" do
    @tag :capture_log
    test "returns true for connected agents, false otherwise" do
      refute AgentConnectionManager.connected?("srv-1")

      AgentConnectionManager.agent_connected(sample_report("srv-1"))
      :sys.get_state(AgentConnectionManager)

      assert AgentConnectionManager.connected?("srv-1")
    end
  end

  describe "crash recovery" do
    @tag :capture_log
    test "starts with an empty table after restart" do
      AgentConnectionManager.agent_connected(sample_report("srv-1"))
      :sys.get_state(AgentConnectionManager)
      assert AgentConnectionManager.connected?("srv-1")

      # Simulate crash + restart — stop_supervised cleans up the test
      # supervisor's child reference so we can start_supervised again.
      stop_supervised!(AgentConnectionManager)
      start_supervised!(AgentConnectionManager)

      # Table is empty after restart — agents re-announce to refill it
      refute AgentConnectionManager.connected?("srv-1")
      assert [] == AgentConnectionManager.list_agents()
    end
  end

  describe "handle_info node monitoring" do
    @tag :capture_log
    test "removes the agent from ETS when its node goes down" do
      report = sample_report("srv-nodedown")
      AgentConnectionManager.agent_connected(report)
      :sys.get_state(AgentConnectionManager)
      assert AgentConnectionManager.connected?("srv-nodedown")

      send(Process.whereis(AgentConnectionManager), {:nodedown, report.node})
      :sys.get_state(AgentConnectionManager)

      refute AgentConnectionManager.connected?("srv-nodedown")
    end

    test "ignores nodedown messages for unknown nodes" do
      AgentConnectionManager.agent_connected(sample_report("srv-keep"))
      :sys.get_state(AgentConnectionManager)

      send(Process.whereis(AgentConnectionManager), {:nodedown, :stranger@host})
      :sys.get_state(AgentConnectionManager)

      assert AgentConnectionManager.connected?("srv-keep")
    end

    test "ignores nodeup messages" do
      AgentConnectionManager.agent_connected(sample_report("srv-up"))
      :sys.get_state(AgentConnectionManager)

      send(Process.whereis(AgentConnectionManager), {:nodeup, :whatever@host})
      :sys.get_state(AgentConnectionManager)

      assert AgentConnectionManager.connected?("srv-up")
    end
  end

  describe "health_transition cast" do
    test "merges the health status onto the matching application entry" do
      AgentConnectionManager.agent_connected(sample_report("srv-ht"))
      :sys.get_state(AgentConnectionManager)

      transition = %{
        application: "my-api",
        from: :healthy,
        to: :unhealthy,
        timestamp: DateTime.utc_now()
      }

      GenServer.cast(AgentConnectionManager, {:health_transition, "srv-ht", transition})
      :sys.get_state(AgentConnectionManager)

      %{applications: [app]} = AgentConnectionManager.get_agent_state("srv-ht")
      assert app.health == :unhealthy
    end

    @tag :capture_log
    test "logs a warning and is a no-op for an unknown server_id" do
      transition = %{
        application: "my-api",
        from: :healthy,
        to: :unhealthy,
        timestamp: DateTime.utc_now()
      }

      GenServer.cast(AgentConnectionManager, {:health_transition, "unknown-srv", transition})
      :sys.get_state(AgentConnectionManager)

      assert AgentConnectionManager.get_agent_state("unknown-srv") == nil
    end

    test "is a no-op when the application isn't in the agent's report" do
      AgentConnectionManager.agent_connected(sample_report("srv-noapp"))
      :sys.get_state(AgentConnectionManager)

      transition = %{
        application: "nonexistent-app",
        from: :unknown,
        to: :unhealthy,
        timestamp: DateTime.utc_now()
      }

      GenServer.cast(AgentConnectionManager, {:health_transition, "srv-noapp", transition})
      :sys.get_state(AgentConnectionManager)

      %{applications: apps} = AgentConnectionManager.get_agent_state("srv-noapp")
      refute Enum.any?(apps, &(&1.application_name == "nonexistent-app"))
    end
  end
end
