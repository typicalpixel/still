defmodule Still.Agent.ConsoleManagerTest do
  use ExUnit.Case, async: false

  alias Still.Agent.ApplicationState
  alias Still.Agent.ConsoleManager
  alias Still.Agent.StatePersistence

  describe "sessions" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "still-cm-#{System.unique_integer([:positive])}")

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

      start_supervised!(ConsoleManager)
      %{tmp_dir: tmp_dir}
    end

    test "rejects an application with no persisted state" do
      assert {:error, :not_deployed} = open(%{application: "ghost"})
    end

    test "rejects a slot that is not active" do
      write_state("app1", "green")
      assert {:error, :slot_not_active} = open(%{application: "app1"})
    end

    test "rejects a missing slot env file", %{tmp_dir: tmp_dir} do
      write_state("app1", "blue")
      File.mkdir_p!(Path.join(tmp_dir, "app1/current_blue"))
      assert {:error, :not_deployed} = open(%{application: "app1"})
    end

    test "reports a spawn failure for a missing executable", %{tmp_dir: tmp_dir} do
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")
      assert {:error, {:spawn_failed, _}} = open(%{application: "app1"})
    end

    test "runs an exec_console override verbatim and round-trips bytes", %{tmp_dir: tmp_dir} do
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, sid} = open(%{application: "app1", exec_console: "/bin/cat"})

      ConsoleManager.resize(node(), sid, 30, 100)
      ConsoleManager.input(node(), sid, "ping\r")
      assert_receive {:console_output, ^sid, data}, 5000
      assert data =~ "ping"

      ConsoleManager.close(node(), sid)
      assert_receive {:console_exit, ^sid, _status}, 5000
    end

    test "spawns the console with a UTF-8 locale and a colors .iex.exs", %{tmp_dir: tmp_dir} do
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, sid} = open(%{exec_console: "/bin/sh"})
      ConsoleManager.input(node(), sid, "echo loc=$LANG home=$HOME\r")

      out = collect_until(sid, "loc=")
      assert out =~ "loc=C.UTF-8"
      assert out =~ "home=#{Path.join(tmp_dir, "app1")}/.console"

      iex_exs = Path.join([tmp_dir, "app1", ".console", ".iex.exs"])
      assert File.read!(iex_exs) =~ "colors: [enabled: true]"
    end

    test "ignores casts and monitor messages for unknown sessions" do
      pid = Process.whereis(ConsoleManager)

      ConsoleManager.close(node(), 0)
      ConsoleManager.input(node(), 0, "x")
      send(pid, {:DOWN, 999_999_999, :process, self(), :normal})
      send(pid, {:DOWN, make_ref(), :process, self(), :normal})
      send(pid, {:stdout, 0, "late"})
      send(pid, {:flush, 0})
      send(pid, {:session_timeout, 0, :idle})
      send(pid, :unrelated)

      assert Process.alive?(pid)
      assert {:error, :not_deployed} = open(%{application: "ghost"})
    end

    test "emits telemetry across the session lifecycle", %{tmp_dir: tmp_dir} do
      ref = attach_telemetry([:opened, :rejected, :output, :reaped])
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      # rejected (unknown app)
      open(%{application: "ghost"})
      assert_receive {^ref, [:still, :console, :rejected], %{count: 1}, %{reason: :not_deployed}}

      # opened
      assert {:ok, sid} = open(%{exec_console: "/bin/cat"})
      assert_receive {^ref, [:still, :console, :opened], %{active: 1}, %{application: "app1"}}

      # output
      ConsoleManager.input(node(), sid, "hi\r")
      assert_receive {^ref, [:still, :console, :output], %{bytes: bytes}, %{application: "app1"}}
      assert bytes > 0

      # reaped, tagged by cause
      ConsoleManager.close(node(), sid)
      assert_receive {^ref, [:still, :console, :reaped], %{active: 0}, %{cause: :closed}}, 5000
    end

    test "tags reaped telemetry by cause", %{tmp_dir: tmp_dir} do
      ref = attach_telemetry([:reaped])
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      with_console_config(idle_timeout_ms: 60)
      assert {:ok, _sid} = open(%{exec_console: "/bin/cat"})
      assert_receive {^ref, [:still, :console, :reaped], _, %{cause: :timeout_idle}}, 5000
    end

    test "caps concurrent sessions per application and user", %{tmp_dir: tmp_dir} do
      with_console_config(max_sessions_per_app_user: 1)
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, _sid} = open(%{exec_console: "/bin/cat", user_id: "u1"})
      assert {:error, :session_limit} = open(%{exec_console: "/bin/cat", user_id: "u1"})
      assert {:ok, _sid} = open(%{exec_console: "/bin/cat", user_id: "u2"})
    end

    test "caps total sessions per agent", %{tmp_dir: tmp_dir} do
      with_console_config(max_sessions: 1)
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, _sid} = open(%{exec_console: "/bin/cat", user_id: "u1"})
      assert {:error, :agent_session_limit} = open(%{exec_console: "/bin/cat", user_id: "u2"})
    end

    test "rate-limits open attempts per user" do
      with_console_config(max_opens_per_minute: 2)

      assert {:error, :not_deployed} = open(%{application: "ghost", user_id: "u1"})
      assert {:error, :not_deployed} = open(%{application: "ghost", user_id: "u1"})
      assert {:error, :rate_limited} = open(%{application: "ghost", user_id: "u1"})
      assert {:error, :not_deployed} = open(%{application: "ghost", user_id: "u2"})
    end

    test "reaps an idle session", %{tmp_dir: tmp_dir} do
      with_console_config(idle_timeout_ms: 80)
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, sid} = open(%{exec_console: "/bin/cat"})
      assert_receive {:console_timeout, ^sid, :idle}, 5000
      assert_receive {:console_exit, ^sid, _}, 5000
    end

    test "reaps a session at the absolute cap", %{tmp_dir: tmp_dir} do
      with_console_config(absolute_timeout_ms: 80)
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, sid} = open(%{exec_console: "/bin/cat"})
      assert_receive {:console_timeout, ^sid, :absolute}, 5000
      assert_receive {:console_exit, ^sid, _}, 5000
    end

    test "drops input beyond the paste cap until the window resets", %{tmp_dir: tmp_dir} do
      with_console_config(input_rate_bytes_per_sec: 10, input_window_ms: 500)
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, sid} = open(%{exec_console: "/bin/cat"})

      ConsoleManager.input(node(), sid, "12345678\r")
      assert collect_until(sid, "12345678") =~ "12345678"

      # Over the window budget: dropped, so no echo comes back.
      ConsoleManager.input(node(), sid, "wxyz\r")
      refute_receive {:console_output, ^sid, _}, 600

      # The refute wait outlasted the window; the budget has reset.
      ConsoleManager.input(node(), sid, "abcd\r")
      assert collect_until(sid, "abcd") =~ "abcd"
    end

    test "rate-caps output and marks dropped bytes", %{tmp_dir: tmp_dir} do
      with_console_config(
        output_buffer_max_bytes: 100,
        output_rate_bytes_per_sec: 400,
        output_flush_ms: 10
      )

      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, sid} = open(%{exec_console: "/bin/cat"})
      ConsoleManager.input(node(), sid, String.duplicate("a", 256) <> "\r")
      assert collect_until(sid, "[output truncated]") =~ "aaaa"
    end

    test "drops output arriving against a full buffer", %{tmp_dir: tmp_dir} do
      with_console_config(output_buffer_max_bytes: 0, output_flush_ms: 10)
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, sid} = open(%{exec_console: "/bin/cat"})
      ConsoleManager.input(node(), sid, "hello\r")

      out = collect_until(sid, "[output truncated]")
      refute out =~ "hello"
    end

    test "coalesces chunks arriving mid-flush-cycle", %{tmp_dir: tmp_dir} do
      # 1 byte per 10ms flush: the second chunk arrives while a flush is
      # already scheduled and joins the same buffer.
      with_console_config(output_rate_bytes_per_sec: 100, output_flush_ms: 10)
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, sid} = open(%{exec_console: "/bin/cat"})
      ConsoleManager.input(node(), sid, "one\r")
      assert_receive {:console_output, ^sid, _first}, 5000

      ConsoleManager.input(node(), sid, "two\r")
      assert collect_until(sid, "two")
    end

    test "drains buffered output when the console exits", %{tmp_dir: tmp_dir} do
      # 1 byte per 10ms flush: the first trickled byte proves the rest is
      # still buffered when the session closes.
      with_console_config(output_rate_bytes_per_sec: 100, output_flush_ms: 10)
      write_state("app1", "blue")
      prepare_slot(tmp_dir, "app1")

      assert {:ok, sid} = open(%{exec_console: "/bin/cat"})
      ConsoleManager.input(node(), sid, "buffered tail\r")
      assert_receive {:console_output, ^sid, _first}, 5000
      ConsoleManager.close(node(), sid)

      assert_receive {:console_exit, ^sid, _}, 5000
      assert drain_mailbox(sid) =~ "tail"
    end

    defp with_console_config(overrides) do
      original = Application.get_env(:still, :console)
      Application.put_env(:still, :console, overrides)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:still, :console)
        else
          Application.put_env(:still, :console, original)
        end
      end)
    end

    defp attach_telemetry(events) do
      ref = make_ref()
      test_pid = self()
      handler_id = {__MODULE__, ref}

      :telemetry.attach_many(
        handler_id,
        Enum.map(events, &[:still, :console, &1]),
        fn name, measurements, metadata, _ ->
          send(test_pid, {ref, name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      ref
    end

    defp drain_mailbox(sid, acc \\ "") do
      receive do
        {:console_output, ^sid, data} -> drain_mailbox(sid, acc <> data)
      after
        0 -> acc
      end
    end

    defp collect_until(sid, needle, acc \\ "") do
      if acc =~ needle do
        acc
      else
        receive do
          {:console_output, ^sid, data} -> collect_until(sid, needle, acc <> data)
        after
          5000 -> flunk("never received #{inspect(needle)}; got: #{inspect(acc)}")
        end
      end
    end

    defp open(params) do
      defaults = %{
        application: "app1",
        slot: :blue,
        exec_command: "bin/app start",
        owner: self(),
        rows: 24,
        cols: 80
      }

      ConsoleManager.open(node(), Map.merge(defaults, params))
    end

    defp write_state(application, active_slot) do
      :ok =
        StatePersistence.write(application, %ApplicationState{
          type: "elixir_release",
          active_slot: active_slot
        })
    end

    defp prepare_slot(tmp_dir, application) do
      app_dir = Path.join(tmp_dir, application)
      File.mkdir_p!(Path.join(app_dir, "current_blue"))
      File.mkdir_p!(Path.join(app_dir, "slots"))
      File.write!(Path.join(app_dir, "slots/blue.env"), "PORT=4001\n")
    end
  end

  describe "derive_console_command/1" do
    test "swaps a bare trailing start subcommand" do
      assert {:ok, "bin/app remote"} = ConsoleManager.derive_console_command("bin/app start")
    end

    test "swaps each release subcommand variant" do
      for sub <- ~w(start start_iex daemon daemon_iex) do
        assert {:ok, "bin/app remote"} = ConsoleManager.derive_console_command("bin/app #{sub}")
      end
    end

    test "keeps a launcher prefix intact" do
      assert {:ok, "/usr/bin/doppler run -- bin/forge remote"} =
               ConsoleManager.derive_console_command("/usr/bin/doppler run -- bin/forge start")
    end

    test "rejects a subcommand hidden inside a quoted argument" do
      assert {:error, :needs_exec_console} =
               ConsoleManager.derive_console_command("sops exec-env secrets.env 'bin/app start'")
    end

    test "rejects a command with trailing flags" do
      assert {:error, :needs_exec_console} =
               ConsoleManager.derive_console_command("bin/app start --verbose")
    end

    test "rejects a command with no release subcommand" do
      assert {:error, :needs_exec_console} =
               ConsoleManager.derive_console_command("bin/run-server")
    end
  end
end
