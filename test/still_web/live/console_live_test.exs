defmodule StillWeb.ConsoleLiveTest do
  use StillWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Still.AccountsFixtures
  alias Still.Agent.ApplicationState
  alias Still.Agent.ConsoleManager
  alias Still.Agent.StatePersistence
  alias Still.AgentConnectionManager
  alias Still.AgentFixtures
  alias Still.ApplicationsFixtures
  alias Still.Audit
  alias Still.FleetFixtures

  defp log_in_admin(%{conn: conn}) do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  describe "authorization" do
    test "unauthenticated redirects to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/applications/some-app/console")
      assert path == ~p"/users/log-in"
    end

    test "viewer is redirected to the dashboard", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/applications/some-app/console")
    end

    test "deployer is allowed through the gate", %{conn: conn} do
      deployer = AccountsFixtures.user_fixture(%{role: :deployer})
      conn = log_in_user(conn, deployer)
      {:ok, _lv, html} = live(conn, ~p"/applications/nope/console")
      assert html =~ "Application not found"
    end
  end

  describe "as an admin" do
    setup :log_in_admin

    test "unknown application renders not found", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/applications/nope/console")
      assert html =~ "Application not found"
    end

    test "static_site application is redirected back with a flash", %{conn: conn} do
      app =
        ApplicationsFixtures.application_fixture(%{
          type: :static_site,
          exec_command: nil,
          health_check: nil
        })

      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(conn, ~p"/applications/#{app.name}/console")

      assert to == ~p"/applications/#{app.name}"
      assert flash["error"] =~ "only available for Elixir release applications"
    end

    test "shows a failure when no connected server runs the application", %{conn: conn} do
      app = ApplicationsFixtures.application_fixture()

      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.name}/console")

      assert html =~ "Could not attach"
      assert html =~ "No connected server is running this application."
    end
  end

  describe "open failures" do
    setup :log_in_admin

    test "reports a launch command the swap cannot handle", %{conn: conn} do
      %{app: app} =
        build_console_env(%{exec_command: "bin/run-server"}, script: false, env_file: false)

      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.name}/console")
      assert html =~ "too complex to derive a console command"
    end

    test "exec_console overrides an underivable launch command", %{conn: conn} do
      %{app: app} =
        build_console_env(%{exec_command: "bin/run-server", exec_console: "/bin/cat"}, [])

      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")
      assert render(lv) =~ "Attached to"

      render_hook(lv, "input", %{"data" => "override works\r"})
      assert_push_event(lv, "output", %{d: d}, 5000)
      assert Base.decode64!(d) =~ "override"
    end

    test "reports an application with no agent-side state", %{conn: conn} do
      %{app: app} = build_console_env(%{}, state: false, script: false, env_file: false)

      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.name}/console")
      assert html =~ "not deployed on the selected server"
    end

    test "reports a slot flip between resolve and open", %{conn: conn} do
      %{app: app} = build_console_env(%{}, active_slot: "green", script: false, env_file: false)

      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.name}/console")
      assert html =~ "deployment flipped while connecting"
    end

    test "reports a spawn failure and closes without a session", %{conn: conn} do
      %{app: app} = build_console_env(%{}, script: false)

      {:ok, lv, html} = live(conn, ~p"/applications/#{app.name}/console")
      assert html =~ "Could not open a console session"

      # No session was opened, so closing the LiveView records no audit row.
      GenServer.stop(lv.pid)
      assert Audit.list(%{type: :console_closed, subject_id: app.id}) == []
    end
  end

  describe "a live session" do
    setup :log_in_admin
    setup :deployed_application

    test "opens, round-trips bytes, resizes, and audits open/close", %{
      conn: conn,
      app: app,
      server: server
    } do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      assert render(lv) =~ "Attached to"
      assert render(lv) =~ server.name

      [opened] = Audit.list(%{type: :console_opened, subject_id: app.id})
      assert opened.subject_type == "application"
      assert opened.payload["server"] == server.name
      assert opened.payload["slot"] == "blue"
      refute Map.has_key?(opened.payload, "ip")

      render_hook(lv, "resize", %{"cols" => 100, "rows" => 30})
      render_hook(lv, "input", %{"data" => "hello console\r"})
      assert await_output(lv) =~ "hello console"

      GenServer.stop(lv.pid)

      [closed] = Audit.list(%{type: :console_closed, subject_id: app.id})
      assert closed.payload["server"] == server.name
      assert is_integer(closed.payload["duration_s"])
    end

    test "shows session ended with a reconnect option when the console process exits",
         %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      # Ctrl-D ends `cat`, the stand-in console process.
      render_hook(lv, "input", %{"data" => "\x04"})

      assert_push_event(lv, "exit", %{}, 5000)
      assert render(lv) =~ "Session ended"
      assert render(lv) =~ "Reconnect"

      lv |> element("button", "Reconnect") |> render_click()
      assert render(lv) =~ "Attached to"
    end

    test "the Disconnect button ends the session", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")
      assert render(lv) =~ "Disconnect"

      lv |> element("button", "Disconnect") |> render_click()

      assert_push_event(lv, "exit", %{}, 5000)
      html = render(lv)
      assert html =~ "Session ended"
      assert html =~ "Reconnect"
      refute html =~ ">Disconnect<"
      assert [_closed] = Audit.list(%{type: :console_closed, subject_id: app.id})
    end

    test "classifies a limited-shell attach failure", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      # `cat` writes the line back, so typed text lands in the output tail.
      render_hook(lv, "input", %{"data" => "the limited shell warning\r"})
      render_hook(lv, "input", %{"data" => "\x04"})

      assert_push_event(lv, "exit", %{}, 5000)
      html = render(lv)
      assert html =~ "Could not attach"
      assert html =~ "TERM/terminfo problem"
    end

    test "classifies a distribution-disabled attach failure", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      render_hook(lv, "input", %{"data" => "Could not contact remote node\r"})
      render_hook(lv, "input", %{"data" => "\x04"})

      assert_push_event(lv, "exit", %{}, 5000)
      html = render(lv)
      assert html =~ "Could not attach"
      assert html =~ "Erlang distribution"
    end

    test "classifies a cookie-mismatch attach failure", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      render_hook(lv, "input", %{"data" => "Invalid challenge reply\r"})
      render_hook(lv, "input", %{"data" => "\x04"})

      assert_push_event(lv, "exit", %{}, 5000)
      html = render(lv)
      assert html =~ "Could not attach"
      assert html =~ "Cookie mismatch"
    end

    test "ignores unrelated messages", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      send(lv.pid, :unrelated)
      send(lv.pid, {:nodedown, :other@nowhere})
      assert render(lv) =~ "Attached to"
    end

    test "closes the session when the agent node goes down", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      send(lv.pid, {:nodedown, node()})

      assert_push_event(lv, "exit", %{}, 5000)
      html = render(lv)
      assert html =~ "Could not attach"
      assert html =~ "agent disconnected"
      assert [_closed] = Audit.list(%{type: :console_closed, subject_id: app.id})
    end

    test "reports an idle timeout", %{conn: conn, app: app} do
      with_console_config(idle_timeout_ms: 100)

      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      assert_push_event(lv, "exit", %{}, 5000)
      html = render(lv)
      assert html =~ "Session ended"
      assert html =~ "timed out after inactivity"
    end

    test "reports the absolute session cap", %{conn: conn, app: app} do
      with_console_config(absolute_timeout_ms: 100)

      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      assert_push_event(lv, "exit", %{}, 5000)
      assert render(lv) =~ "maximum duration"
    end
  end

  describe "session limits" do
    setup :log_in_admin

    test "per-application session limit", %{conn: conn} do
      with_console_config(max_sessions_per_app_user: 0)
      %{app: app} = build_console_env(%{}, [])

      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.name}/console")
      assert html =~ "maximum number of console sessions"
    end

    test "per-agent session limit", %{conn: conn} do
      with_console_config(max_sessions: 0)
      %{app: app} = build_console_env(%{}, [])

      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.name}/console")
      assert html =~ "at its console session limit"
    end

    test "open rate limit", %{conn: conn} do
      with_console_config(max_opens_per_minute: 0)
      %{app: app} = build_console_env(%{}, [])

      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.name}/console")
      assert html =~ "Too many console opens"
    end
  end

  describe "multi-server" do
    setup :log_in_admin
    setup :two_server_application

    test "shows a picker, displays version, and reattaches on switch", %{
      conn: conn,
      app: app,
      servers: {server_a, server_b}
    } do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      html = render(lv)
      # First healthy server is the default attach.
      assert html =~ "Attached to"
      assert html =~ server_a.name
      assert html =~ server_b.name
      # Version comes from the agent report.
      assert html =~ "1.0.0"

      [opened_a] = Audit.list(%{type: :console_opened, subject_id: app.id})
      assert opened_a.payload["server"] == server_a.name

      # Switching servers closes the first session and opens on the second.
      lv
      |> element("button[phx-value-server_id='#{server_b.id}']")
      |> render_click()

      assert render(lv) =~ "Attached to"
      assert [_closed] = Audit.list(%{type: :console_closed, subject_id: app.id})

      opened = Audit.list(%{type: :console_opened, subject_id: app.id})
      assert Enum.any?(opened, &(&1.payload["server"] == server_b.name))
    end

    test "selecting the already-attached server is a no-op", %{
      conn: conn,
      app: app,
      servers: {server_a, _server_b}
    } do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.name}/console")

      lv
      |> element("button[phx-value-server_id='#{server_a.id}']")
      |> render_click()

      assert render(lv) =~ "Attached to"
      # No extra open/close churn.
      assert length(Audit.list(%{type: :console_opened, subject_id: app.id})) == 1
      assert Audit.list(%{type: :console_closed, subject_id: app.id}) == []
    end
  end

  defp deployed_application(_ctx), do: build_console_env(%{}, [])

  defp two_server_application(_ctx) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "still-console-#{System.unique_integer([:positive])}")

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

    app = ApplicationsFixtures.application_fixture()
    server_a = FleetFixtures.server_fixture(%{name: "edge-a"})
    server_b = FleetFixtures.server_fixture(%{name: "edge-b"})
    ApplicationsFixtures.application_server_fixture(app, server_a)
    ApplicationsFixtures.application_server_fixture(app, server_b)

    # Both agents live on this node in the test, so one on-disk state and one
    # console stand-in serve both reported servers.
    bin_dir = Path.join(tmp_dir, "#{app.name}/current_blue/bin")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(Path.join(tmp_dir, "#{app.name}/slots"))
    File.write!(Path.join(tmp_dir, "#{app.name}/slots/blue.env"), "PORT=4001\n")
    script = Path.join(bin_dir, "app")
    File.write!(script, "#!/bin/sh\nexec cat\n")
    File.chmod!(script, 0o755)

    :ok =
      StatePersistence.write(app.name, %ApplicationState{
        type: "elixir_release",
        active_slot: "blue"
      })

    start_supervised!(AgentConnectionManager)
    start_supervised!(ConsoleManager)

    for server <- [server_a, server_b] do
      AgentConnectionManager.agent_connected(
        AgentFixtures.agent_report_fixture(%{
          server_id: server.id,
          node: node(),
          applications: [
            AgentFixtures.reported_application_fixture(%{
              application_name: app.name,
              active_slot: :blue,
              current_version: "1.0.0"
            })
          ]
        })
      )
    end

    :sys.get_state(AgentConnectionManager)

    %{app: app, servers: {server_a, server_b}}
  end

  defp build_console_env(app_attrs, opts) do
    tmp_dir =
      Path.join(System.tmp_dir!(), "still-console-#{System.unique_integer([:positive])}")

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

    app = ApplicationsFixtures.application_fixture(app_attrs)
    server = FleetFixtures.server_fixture()
    ApplicationsFixtures.application_server_fixture(app, server)

    app_dir = Path.join(tmp_dir, app.name)
    bin_dir = Path.join(app_dir, "current_blue/bin")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(Path.join(app_dir, "slots"))

    if Keyword.get(opts, :env_file, true) do
      File.write!(Path.join(app_dir, "slots/blue.env"), "PORT=4001\n")
    end

    if Keyword.get(opts, :script, true) do
      # Stand-in for `bin/<app> remote`: stays attached until stdin closes.
      script = Path.join(bin_dir, "app")
      File.write!(script, "#!/bin/sh\nexec cat\n")
      File.chmod!(script, 0o755)
    end

    if Keyword.get(opts, :state, true) do
      :ok =
        StatePersistence.write(app.name, %ApplicationState{
          type: "elixir_release",
          active_slot: Keyword.get(opts, :active_slot, "blue")
        })
    end

    start_supervised!(AgentConnectionManager)
    start_supervised!(ConsoleManager)

    AgentConnectionManager.agent_connected(
      AgentFixtures.agent_report_fixture(%{
        server_id: server.id,
        node: node(),
        applications: [
          AgentFixtures.reported_application_fixture(%{
            application_name: app.name,
            active_slot: :blue
          })
        ]
      })
    )

    # agent_connected is a cast; flush it before tests read the ETS table.
    :sys.get_state(AgentConnectionManager)

    %{app: app, server: server}
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

  defp await_output(lv, acc \\ "") do
    assert_push_event(lv, "output", %{d: d}, 5000)
    acc = acc <> Base.decode64!(d)
    if acc =~ "hello console", do: acc, else: await_output(lv, acc)
  end
end
