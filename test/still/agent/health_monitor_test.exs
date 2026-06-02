defmodule Still.Agent.HealthMonitorTest do
  use ExUnit.Case, async: false

  alias Still.Agent.HealthMonitor

  defp default_config(overrides \\ %{}) do
    Map.merge(
      %{
        port: 4000,
        path: "/health",
        interval_ms: 60_000,
        timeout_ms: 1_000,
        failure_threshold: 2
      },
      overrides
    )
  end

  defp build_state(apps \\ %{}, reporter \\ fn _ -> :ok end) do
    %{apps: apps, reporter: reporter}
  end

  defp build_app(overrides \\ %{}) do
    Map.merge(
      %{
        port: 4000,
        path: "/health",
        interval_ms: 60_000,
        timeout_ms: 1_000,
        failure_threshold: 2,
        consecutive_failures: 0,
        status: :unknown,
        last_checked_at: nil
      },
      overrides
    )
  end

  describe "init/1" do
    test "starts with empty registry and no-op default reporter" do
      assert {:ok, state} = HealthMonitor.init([])
      assert state.apps == %{}
      assert is_function(state.reporter, 1)
    end

    test "uses an injected reporter when provided" do
      reporter = fn _ -> :ok end
      assert {:ok, %{reporter: ^reporter}} = HealthMonitor.init(reporter: reporter)
    end

    test "default reporter is a no-op that returns :ok" do
      {:ok, state} = HealthMonitor.init([])
      assert :ok = state.reporter.(%{application: "my-api", from: :unknown, to: :healthy})
    end
  end

  describe "handle_call/3 :register" do
    test "adds the app and queues an immediate check" do
      state = build_state()

      assert {:reply, :ok, new_state} =
               HealthMonitor.handle_call(
                 {:register, "my-api", default_config()},
                 self(),
                 state
               )

      assert %{port: 4000, path: "/health", status: :unknown, consecutive_failures: 0} =
               new_state.apps["my-api"]

      assert_receive {:check, "my-api"}, 100
    end
  end

  describe "handle_call/3 :unregister" do
    test "removes the app from the registry" do
      state = build_state(%{"my-api" => build_app()})

      assert {:reply, :ok, new_state} =
               HealthMonitor.handle_call({:unregister, "my-api"}, self(), state)

      assert new_state.apps == %{}
    end

    test "is a no-op when the app isn't registered" do
      state = build_state()

      assert {:reply, :ok, ^state} =
               HealthMonitor.handle_call({:unregister, "ghost"}, self(), state)
    end
  end

  describe "handle_call/3 :status" do
    test "returns the current status when registered" do
      state = build_state(%{"my-api" => build_app(%{status: :healthy})})

      assert {:reply, {:ok, :healthy}, ^state} =
               HealthMonitor.handle_call({:status, "my-api"}, self(), state)
    end

    test "returns :not_found when the app isn't registered" do
      state = build_state()

      assert {:reply, {:error, :not_found}, ^state} =
               HealthMonitor.handle_call({:status, "ghost"}, self(), state)
    end
  end

  describe "handle_call/3 :list" do
    test "returns the names of all registered apps" do
      state =
        build_state(%{
          "alpha" => build_app(),
          "bravo" => build_app()
        })

      assert {:reply, names, ^state} = HealthMonitor.handle_call(:list, self(), state)
      assert Enum.sort(names) == ["alpha", "bravo"]
    end

    test "returns an empty list when none are registered" do
      state = build_state()
      assert {:reply, [], ^state} = HealthMonitor.handle_call(:list, self(), state)
    end
  end

  describe "handle_info/2 :check — successful probe" do
    setup do
      test_pid = self()
      reporter = fn t -> send(test_pid, {:transition, t}) end
      %{reporter: reporter}
    end

    test "transitions :unknown → :healthy and reports the transition", %{reporter: reporter} do
      Req.Test.stub(HealthMonitor, fn conn ->
        assert conn.request_path == "/health"
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      state = build_state(%{"my-api" => build_app()}, reporter)

      assert {:noreply, new_state} = HealthMonitor.handle_info({:check, "my-api"}, state)
      app = new_state.apps["my-api"]
      assert app.status == :healthy
      assert app.consecutive_failures == 0
      assert %DateTime{} = app.last_checked_at

      assert_receive {:transition, %{application: "my-api", from: :unknown, to: :healthy}}
    end

    test "does NOT report when status is unchanged", %{reporter: reporter} do
      Req.Test.stub(HealthMonitor, fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      state =
        build_state(%{"my-api" => build_app(%{status: :healthy})}, reporter)

      assert {:noreply, _new_state} = HealthMonitor.handle_info({:check, "my-api"}, state)
      refute_received {:transition, _}
    end

    @tag :capture_log
    test "transitions :unhealthy → :healthy on recovery", %{reporter: reporter} do
      Req.Test.stub(HealthMonitor, fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      state =
        build_state(
          %{"my-api" => build_app(%{status: :unhealthy, consecutive_failures: 5})},
          reporter
        )

      assert {:noreply, new_state} = HealthMonitor.handle_info({:check, "my-api"}, state)
      assert new_state.apps["my-api"].status == :healthy
      assert new_state.apps["my-api"].consecutive_failures == 0

      assert_receive {:transition, %{from: :unhealthy, to: :healthy}}
    end
  end

  describe "handle_info/2 :check — failing probe" do
    setup do
      test_pid = self()
      reporter = fn t -> send(test_pid, {:transition, t}) end

      Req.Test.stub(HealthMonitor, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      %{reporter: reporter}
    end

    @tag :capture_log
    test "increments consecutive_failures without changing status until threshold",
         %{reporter: reporter} do
      state =
        build_state(
          %{"my-api" => build_app(%{status: :healthy, failure_threshold: 2})},
          reporter
        )

      {:noreply, state} = HealthMonitor.handle_info({:check, "my-api"}, state)
      assert state.apps["my-api"].status == :healthy
      assert state.apps["my-api"].consecutive_failures == 1
      refute_received {:transition, _}

      {:noreply, state} = HealthMonitor.handle_info({:check, "my-api"}, state)
      assert state.apps["my-api"].status == :healthy
      assert state.apps["my-api"].consecutive_failures == 2
      refute_received {:transition, _}
    end

    @tag :capture_log
    test "transitions :healthy → :unhealthy when failures exceed threshold",
         %{reporter: reporter} do
      state =
        build_state(
          %{
            "my-api" =>
              build_app(%{
                status: :healthy,
                failure_threshold: 2,
                consecutive_failures: 2
              })
          },
          reporter
        )

      {:noreply, new_state} = HealthMonitor.handle_info({:check, "my-api"}, state)
      assert new_state.apps["my-api"].status == :unhealthy
      assert new_state.apps["my-api"].consecutive_failures == 3

      assert_receive {:transition, %{from: :healthy, to: :unhealthy}}
    end

    @tag :capture_log
    test "stays :unhealthy without re-reporting on subsequent failures",
         %{reporter: reporter} do
      state =
        build_state(
          %{
            "my-api" =>
              build_app(%{
                status: :unhealthy,
                failure_threshold: 2,
                consecutive_failures: 5
              })
          },
          reporter
        )

      {:noreply, new_state} = HealthMonitor.handle_info({:check, "my-api"}, state)
      assert new_state.apps["my-api"].status == :unhealthy
      refute_received {:transition, _}
    end
  end

  describe "handle_info/2 :check — unregistered app" do
    test "is a no-op when the app is no longer registered" do
      state = build_state()

      assert {:noreply, ^state} = HealthMonitor.handle_info({:check, "ghost"}, state)
    end
  end

  describe "start_link/1 + register/2 integration" do
    test "starts the GenServer and accepts a registration" do
      pid = start_supervised!({HealthMonitor, reporter: fn _ -> :ok end})

      # register/2 queues an immediate first check that runs in the GenServer
      # process (not the test process), so the Req.Test stub must be set and
      # explicitly allowed for that pid before we register — otherwise the
      # check crashes the GenServer with "cannot find mock/stub". A long
      # interval only delays *subsequent* checks, not the first one.
      Req.Test.stub(HealthMonitor, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)
      Req.Test.allow(HealthMonitor, self(), pid)

      assert HealthMonitor.list() == []

      :ok = HealthMonitor.register("my-api", default_config(%{interval_ms: 60_000}))

      assert HealthMonitor.list() == ["my-api"]
      assert {:ok, _status} = HealthMonitor.status("my-api")

      :ok = HealthMonitor.unregister("my-api")
      assert HealthMonitor.list() == []
    end
  end
end
