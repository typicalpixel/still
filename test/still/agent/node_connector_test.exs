defmodule Still.Agent.NodeConnectorTest do
  use Still.DataCase, async: false

  alias Still.Agent.ApplicationState
  alias Still.Agent.NodeConnector
  alias Still.Agent.StatePersistence
  alias Still.AgentConnectionManager

  describe "init/1" do
    test "returns the initial state and queues a :try_connect message" do
      stub = fn _ -> false end

      assert {:ok, state} =
               NodeConnector.init(
                 controller_node: :controller@host,
                 reconnect_interval_ms: 50,
                 connector: stub
               )

      assert state.controller == :controller@host
      assert state.status == :disconnected
      assert state.interval == 50
      assert state.connector == stub

      assert_received :try_connect
    end

    test "uses default reconnect_interval_ms when not given" do
      assert {:ok, state} =
               NodeConnector.init(
                 controller_node: :controller@host,
                 connector: fn _ -> false end
               )

      assert state.interval == 5_000

      # Drain the auto-sent :try_connect so it doesn't leak into other tests.
      assert_received :try_connect
    end

    test "raises if :controller_node is missing" do
      assert_raise KeyError, fn ->
        NodeConnector.init([])
      end
    end
  end

  describe "handle_call/3" do
    test ":status returns the current status field" do
      state = build_state(status: :connected)
      assert {:reply, :connected, ^state} = NodeConnector.handle_call(:status, self(), state)
    end

    test ":controller_node returns the controller field" do
      state = build_state(controller: :foo@bar)

      assert {:reply, :foo@bar, ^state} =
               NodeConnector.handle_call(:controller_node, self(), state)
    end
  end

  describe "handle_info :try_connect" do
    test "moves status to :connected when the connector succeeds" do
      state = build_state(status: :disconnected, connector: fn _ -> true end)

      assert {:noreply, new_state} = NodeConnector.handle_info(:try_connect, state)
      assert new_state.status == :connected
    end

    @tag :capture_log
    test "stays disconnected and schedules a reconnect when the connector fails" do
      state = build_state(status: :disconnected, interval: 30, connector: fn _ -> false end)

      assert {:noreply, new_state} = NodeConnector.handle_info(:try_connect, state)
      assert new_state.status == :disconnected
      assert_receive :try_connect, 100
    end
  end

  describe "handle_info {:nodeup, node}" do
    test "moves status to :connected when the controller comes up" do
      state = build_state(controller: :controller@host, status: :disconnected)

      assert {:noreply, new_state} =
               NodeConnector.handle_info({:nodeup, :controller@host}, state)

      assert new_state.status == :connected
    end

    test "ignores nodeup for unrelated nodes" do
      state = build_state(controller: :controller@host, status: :disconnected)

      assert {:noreply, ^state} =
               NodeConnector.handle_info({:nodeup, :someone_else@host}, state)
    end
  end

  describe "handle_info {:nodedown, node}" do
    @tag :capture_log
    test "moves status to :disconnected and schedules reconnect when the controller drops" do
      state = build_state(controller: :controller@host, status: :connected, interval: 30)

      assert {:noreply, new_state} =
               NodeConnector.handle_info({:nodedown, :controller@host}, state)

      assert new_state.status == :disconnected
      assert_receive :try_connect, 100
    end

    test "ignores nodedown for unrelated nodes" do
      state = build_state(controller: :controller@host, status: :connected)

      assert {:noreply, ^state} =
               NodeConnector.handle_info({:nodedown, :someone_else@host}, state)
    end
  end

  describe "start_link/1 + status/0 + controller_node/0" do
    test "starts the GenServer and answers status queries" do
      pid =
        start_supervised!(
          {NodeConnector,
           controller_node: :fake@nowhere,
           reconnect_interval_ms: 60_000,
           connector: fn _ -> true end}
        )

      assert NodeConnector.controller_node() == :fake@nowhere

      # Wait briefly for the auto-sent :try_connect to process.
      :sys.get_state(pid)

      assert NodeConnector.status() == :connected
    end
  end

  describe "report_application_state/2 — public API" do
    setup do
      start_supervised!(AgentConnectionManager)
      :ok
    end

    setup :tmp_applications_dir

    test "delivers the cast to the running NodeConnector and AgentConnectionManager" do
      # Configure the real server_id the connector reads from app env.
      original_server_id = Application.get_env(:still, :server_id)
      Application.put_env(:still, :server_id, "srv-public-api")

      on_exit(fn ->
        if is_nil(original_server_id) do
          Application.delete_env(:still, :server_id)
        else
          Application.put_env(:still, :server_id, original_server_id)
        end
      end)

      # Start the connector in standalone mode so it announces locally.
      pid =
        start_supervised!(
          {NodeConnector,
           controller_node: Node.self(),
           reconnect_interval_ms: 60_000,
           connector: fn _ -> true end}
        )

      # Wait for the initial :try_connect/announce to process.
      :sys.get_state(pid)
      :sys.get_state(AgentConnectionManager)

      # Now push an update via the public API.
      NodeConnector.report_application_state("my-api", %ApplicationState{
        type: "elixir_release",
        active_slot: "green",
        active_port: 4001,
        current_version: "9.9.9",
        previous_version: "9.9.8",
        last_health_check_at: nil
      })

      :sys.get_state(pid)
      :sys.get_state(AgentConnectionManager)

      report = AgentConnectionManager.get_agent_state("srv-public-api")
      assert [app] = report.applications
      assert app.application_name == "my-api"
      assert app.current_version == "9.9.9"
      assert app.active_slot == "green"
    end
  end

  describe "report_health_transition/1 — public API" do
    setup do
      start_supervised!(AgentConnectionManager)
      :ok
    end

    setup :tmp_applications_dir

    test "delivers the health transition to AgentConnectionManager via NodeConnector" do
      original_server_id = Application.get_env(:still, :server_id)
      Application.put_env(:still, :server_id, "srv-health-api")

      on_exit(fn ->
        if is_nil(original_server_id) do
          Application.delete_env(:still, :server_id)
        else
          Application.put_env(:still, :server_id, original_server_id)
        end
      end)

      pid =
        start_supervised!(
          {NodeConnector,
           controller_node: Node.self(),
           reconnect_interval_ms: 60_000,
           connector: fn _ -> true end}
        )

      :sys.get_state(pid)
      :sys.get_state(AgentConnectionManager)

      # Seed an app entry so the health transition has something to merge into.
      NodeConnector.report_application_state("my-api", %ApplicationState{
        type: "elixir_release",
        active_slot: "blue",
        active_port: 4000,
        current_version: "1.0.0",
        previous_version: nil,
        last_health_check_at: nil
      })

      :sys.get_state(pid)
      :sys.get_state(AgentConnectionManager)

      NodeConnector.report_health_transition(%{
        application: "my-api",
        from: :healthy,
        to: :unhealthy,
        timestamp: DateTime.utc_now()
      })

      :sys.get_state(pid)
      :sys.get_state(AgentConnectionManager)

      report = AgentConnectionManager.get_agent_state("srv-health-api")
      app = Enum.find(report.applications, &(&1.application_name == "my-api"))
      assert app.health == :unhealthy
    end
  end

  describe "build_report/1" do
    setup :tmp_applications_dir

    test "returns an empty application list when no state.json exists" do
      assert %{
               server_id: "srv-empty",
               node: node,
               applications: [],
               connected_at: %DateTime{}
             } = NodeConnector.build_report("srv-empty")

      assert node == Node.self()
    end

    test "includes every application with a readable state.json" do
      :ok =
        StatePersistence.write("my-api", %ApplicationState{
          type: "elixir_release",
          active_slot: "blue",
          active_port: 4000,
          current_version: "1.2.3",
          previous_version: "1.2.2",
          last_health_check_at: nil
        })

      :ok =
        StatePersistence.write("www", %ApplicationState{
          type: "static_site",
          active_slot: "green",
          active_port: nil,
          current_version: "2025-04-01",
          previous_version: nil,
          last_health_check_at: nil
        })

      report = NodeConnector.build_report("srv-with-apps")

      assert report.server_id == "srv-with-apps"
      assert length(report.applications) == 2

      api = Enum.find(report.applications, &(&1.application_name == "my-api"))
      assert api.type == "elixir_release"
      assert api.active_slot == "blue"
      assert api.active_port == 4000
      assert api.current_version == "1.2.3"
      assert api.previous_version == "1.2.2"

      www = Enum.find(report.applications, &(&1.application_name == "www"))
      assert www.type == "static_site"
      assert www.active_slot == "green"
      assert is_nil(www.active_port)
    end

    test "skips applications whose state.json is corrupted", %{tmp_dir: tmp_dir} do
      :ok =
        StatePersistence.write("good", %ApplicationState{
          type: "static_site",
          active_slot: "blue",
          active_port: nil,
          current_version: "1",
          previous_version: nil,
          last_health_check_at: nil
        })

      broken_dir = Path.join(tmp_dir, "broken")
      File.mkdir_p!(broken_dir)
      File.write!(Path.join(broken_dir, "state.json"), "not-json")

      report = NodeConnector.build_report("srv-mixed")
      names = Enum.map(report.applications, & &1.application_name)
      assert "good" in names
      refute "broken" in names
    end
  end

  describe "handle_cast {:report_application_state, ...}" do
    setup do
      # Push path ends at AgentConnectionManager — start it so the cast
      # has somewhere to land, and so the merged state is observable.
      start_supervised!(AgentConnectionManager)
      :ok
    end

    test "is a no-op when server_id is not configured" do
      state = build_state(server_id: nil)

      assert {:noreply, ^state} =
               NodeConnector.handle_cast(
                 {:report_application_state, "my-api", %ApplicationState{type: "static_site"}},
                 state
               )
    end

    test "pushes an update to AgentConnectionManager on the configured controller node" do
      # Pre-seed a connected agent report so the update_application_state
      # call can merge into an existing row.
      AgentConnectionManager.agent_connected(%{
        server_id: "srv-push",
        node: Node.self(),
        connected_at: DateTime.utc_now(),
        applications: [
          %{application_name: "my-api", current_version: "1.0.0", health: :unknown}
        ]
      })

      :sys.get_state(AgentConnectionManager)

      new_state = %ApplicationState{
        type: "elixir_release",
        active_slot: "green",
        active_port: 4001,
        current_version: "2.0.0",
        previous_version: "1.0.0",
        last_health_check_at: nil
      }

      state = build_state(server_id: "srv-push", controller: Node.self())

      assert {:noreply, ^state} =
               NodeConnector.handle_cast(
                 {:report_application_state, "my-api", new_state},
                 state
               )

      :sys.get_state(AgentConnectionManager)

      %{applications: [app]} = AgentConnectionManager.get_agent_state("srv-push")
      assert app.application_name == "my-api"
      assert app.current_version == "2.0.0"
      assert app.active_slot == "green"
      assert app.active_port == 4001
      assert app.previous_version == "1.0.0"
    end
  end

  describe "handle_cast {:report_health_transition, ...}" do
    setup do
      start_supervised!(AgentConnectionManager)
      :ok
    end

    test "is a no-op when server_id is not configured" do
      state = build_state(server_id: nil)
      transition = %{application: "my-api", from: :healthy, to: :unhealthy}

      assert {:noreply, ^state} =
               NodeConnector.handle_cast({:report_health_transition, transition}, state)
    end

    test "forwards the transition to AgentConnectionManager on the controller" do
      AgentConnectionManager.agent_connected(%{
        server_id: "srv-health",
        node: Node.self(),
        connected_at: DateTime.utc_now(),
        applications: [
          %{application_name: "my-api", current_version: "1.0.0", health: :healthy}
        ]
      })

      :sys.get_state(AgentConnectionManager)

      state = build_state(server_id: "srv-health", controller: Node.self())

      transition = %{
        application: "my-api",
        from: :healthy,
        to: :unhealthy,
        timestamp: DateTime.utc_now()
      }

      assert {:noreply, ^state} =
               NodeConnector.handle_cast({:report_health_transition, transition}, state)

      :sys.get_state(AgentConnectionManager)

      %{applications: [app]} = AgentConnectionManager.get_agent_state("srv-health")
      assert app.health == :unhealthy
    end
  end

  describe "standalone :try_connect branch" do
    setup do
      start_supervised!(AgentConnectionManager)
      :ok
    end

    setup :tmp_applications_dir

    test "announces directly to the local AgentConnectionManager without calling connector" do
      # The standalone branch should NEVER call the injected connector —
      # assert that by making it blow up on use.
      connector = fn _ -> raise "connector should not be called in standalone mode" end

      state =
        build_state(
          controller: Node.self(),
          server_id: "srv-standalone",
          connector: connector
        )

      assert {:noreply, new_state} = NodeConnector.handle_info(:try_connect, state)
      assert new_state.status == :connected

      :sys.get_state(AgentConnectionManager)

      # The announce cast should have landed in ETS.
      assert AgentConnectionManager.connected?("srv-standalone")
      report = AgentConnectionManager.get_agent_state("srv-standalone")
      assert report.server_id == "srv-standalone"
      assert report.applications == []
    end
  end

  describe "announce via :nodeup" do
    setup do
      start_supervised!(AgentConnectionManager)
      :ok
    end

    setup :tmp_applications_dir

    test "sends the full state.json-backed report to AgentConnectionManager" do
      :ok =
        StatePersistence.write("my-api", %ApplicationState{
          type: "elixir_release",
          active_slot: "blue",
          active_port: 4000,
          current_version: "1.2.3",
          previous_version: nil,
          last_health_check_at: nil
        })

      state = build_state(controller: Node.self(), server_id: "srv-nodeup")

      assert {:noreply, new_state} =
               NodeConnector.handle_info({:nodeup, Node.self()}, state)

      assert new_state.status == :connected

      :sys.get_state(AgentConnectionManager)

      report = AgentConnectionManager.get_agent_state("srv-nodeup")
      assert [%{application_name: "my-api", current_version: "1.2.3"}] = report.applications
    end
  end

  defp build_state(overrides) do
    base = %{
      controller: :controller@host,
      status: :disconnected,
      interval: 5_000,
      connector: fn _ -> true end,
      server_id: nil
    }

    Enum.into(overrides, base)
  end

  defp tmp_applications_dir(_ctx) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "still-nc-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    original = Application.get_env(:still, :applications_dir)
    Application.put_env(:still, :applications_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      if is_nil(original) do
        Application.delete_env(:still, :applications_dir)
      else
        Application.put_env(:still, :applications_dir, original)
      end
    end)

    %{tmp_dir: tmp_dir}
  end
end
