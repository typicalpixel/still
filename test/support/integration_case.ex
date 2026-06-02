defmodule Still.IntegrationCase do
  @moduledoc """
  Base case for integration tests. Auto-tags the module so it is excluded
  from the default `mix test` run, skips when required host executables
  (`tar`, `systemctl`, `caddy`) are missing, and boots a dedicated Caddy
  instance per test module on free ports.

  ## Tags and running

  Two categories, both excluded by default:

    * `use Still.IntegrationCase` — tags `:integration`. Runs without root.
      Run with `mix test --include integration`.

    * `use Still.IntegrationCase, root: true` — tags `:integration_root`.
      Additionally requires the test process to be running as root (Still's
      DeploymentManager writes to `/etc/systemd/system/` and calls
      `systemctl daemon-reload`, which need root in production). Run with
      `sudo -E mix test --include integration_root`.

  When a test is tagged `:integration_root` and not running as root, the
  whole module skips with a clear reason instead of failing.

  ## Test context

  Each test module receives:
    * `context.caddy.http_port` — Caddy HTTP listen port for response assertions
    * `context.caddy.admin_port` — Caddy admin API port (wired into Still's
      config for the module's duration)
    * `context.applications_dir` — per-module temp directory set as
      Still's `:applications_dir`
  """

  use ExUnit.CaseTemplate

  @required_executables ["caddy", "tar", "systemctl"]

  using opts do
    require_root = Keyword.get(opts, :root, false)
    tag = if require_root, do: :integration_root, else: :integration

    quote do
      @moduletag unquote(tag)

      import Still.IntegrationCase

      setup_all do
        Still.IntegrationCase.setup_integration(require_root: unquote(require_root))
      end
    end
  end

  # six:ignore:start

  @doc """
  Runs the module-level setup for an integration test. Called from the
  `using` block — not normally invoked directly by test code. Checks
  prereqs (root if required, `caddy`/`tar`/`systemctl` on `$PATH`), and
  on success boots a Caddy instance, allocates a temp `applications_dir`,
  and overrides the Still application env for the duration of the module.
  Returns `{:ok, ctx}` on success, `{:skip, reason}` on prereq failure.
  """
  def setup_integration(opts) do
    with :ok <- check_root(opts),
         :ok <- check_executables() do
      boot_test_environment()
    end
  end

  defp check_root(opts) do
    if Keyword.get(opts, :require_root, false) and not running_as_root?() do
      {:skip, "requires root; run with `sudo -E mix test --include integration_root`"}
    else
      :ok
    end
  end

  defp check_executables do
    case missing_executables() do
      [] -> :ok
      missing -> {:skip, "missing host executables: #{Enum.join(missing, ", ")}"}
    end
  end

  defp boot_test_environment do
    artifacts_dir = fresh_artifacts_dir()
    caddy = start_caddy!(artifacts_dir: artifacts_dir)
    apps_dir = fresh_applications_dir()
    original = override_env!(caddy, apps_dir, artifacts_dir)

    ExUnit.Callbacks.on_exit(fn ->
      stop_caddy!(caddy)
      File.rm_rf!(apps_dir)
      File.rm_rf!(artifacts_dir)
      restore_env!(original)
    end)

    {:ok, caddy: caddy, applications_dir: apps_dir, artifacts_dir: artifacts_dir}
  end

  defp running_as_root? do
    {output, 0} = System.cmd("id", ["-u"])
    String.trim(output) == "0"
  end

  defp missing_executables do
    Enum.filter(@required_executables, &is_nil(System.find_executable(&1)))
  end

  @doc """
  Spawns a dedicated Caddy instance on free admin + HTTP ports. Returns a
  map with `:port`, `:os_pid`, `:http_port`, `:admin_port`, `:config_file`.
  The OS pid is captured immediately so `stop_caddy!/1` works from
  `on_exit/1` (where `Port.info` would return nil on an already-closed Port).
  """
  def start_caddy!(opts \\ []) do
    http_port = free_port()
    admin_port = free_port()
    internal_port = free_port()
    artifacts_dir = Keyword.get(opts, :artifacts_dir, System.tmp_dir!())

    config = %{
      # persist: false stops Caddy autosaving to the user's XDG config dir,
      # which (combined with the temp XDG dirs below) keeps test runs from
      # writing to ~/.config|.local — and from leaving root-owned files there
      # when the suite runs under sudo.
      "admin" => %{"listen" => "localhost:#{admin_port}", "config" => %{"persist" => false}},
      "apps" => %{
        "http" => %{
          "servers" => %{
            "still" => %{
              "listen" => [":#{http_port}"],
              "routes" => [],
              "automatic_https" => %{"disable" => true}
            },
            "still_internal" => %{
              "listen" => [":#{internal_port}"],
              "routes" => [
                %{
                  "@id" => "still_artifacts",
                  "match" => [%{"path" => ["/artifacts/*"]}],
                  "handle" => [
                    %{"handler" => "vars", "root" => artifacts_dir},
                    %{"handler" => "rewrite", "strip_path_prefix" => "/artifacts"},
                    %{"handler" => "file_server"}
                  ]
                }
              ]
            }
          }
        }
      }
    }

    config_file =
      Path.join(System.tmp_dir!(), "still-caddy-#{System.unique_integer([:positive])}.json")

    File.write!(config_file, Jason.encode!(config))

    # Point Caddy's XDG dirs at a throwaway directory so its TLS storage and
    # lock files land there instead of the invoking user's home.
    caddy_home =
      Path.join(System.tmp_dir!(), "still-caddy-home-#{System.unique_integer([:positive])}")

    File.mkdir_p!(caddy_home)
    home = String.to_charlist(caddy_home)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("caddy")},
        [
          :binary,
          :exit_status,
          args: ["run", "--config", config_file],
          env: [
            {~c"XDG_CONFIG_HOME", home},
            {~c"XDG_DATA_HOME", home},
            {~c"XDG_CACHE_HOME", home}
          ]
        ]
      )

    # Capture the OS pid now — `on_exit` runs in a separate process after
    # this one has already died, which closes `port` and makes `Port.info`
    # return nil. We need the pid stashed before that happens.
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    wait_for_admin!(admin_port)

    %{
      port: port,
      os_pid: os_pid,
      http_port: http_port,
      admin_port: admin_port,
      internal_port: internal_port,
      config_file: config_file,
      caddy_home: caddy_home
    }
  end

  @doc """
  Stops a Caddy instance previously started with `start_caddy!/0` and
  removes its temporary config file. Idempotent — safe to call multiple
  times or on an already-dead instance.
  """
  def stop_caddy!(%{os_pid: os_pid, config_file: config_file} = caddy) do
    System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    File.rm_rf!(config_file)
    if home = Map.get(caddy, :caddy_home), do: File.rm_rf!(home)
    :ok
  end

  @doc """
  Spawns a Caddy started with `caddy run --resume` (autosave left enabled),
  with XDG pointed at a throwaway `home` so its autosave is isolated to the
  test. On first boot — no autosave yet — Caddy falls back to `config_file`;
  after a config is pushed via the admin API, a restart resumes that instead.
  Used to prove a pushed config survives a crash. Returns the OS pid; pair
  with `await_caddy_admin!/1`, `await_caddy_down!/1`, and a `kill`.
  """
  def start_resume_caddy!(config_file, home) do
    home_cl = String.to_charlist(home)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("caddy")},
        [
          :binary,
          :exit_status,
          args: ["run", "--resume", "--config", config_file],
          env: [
            {~c"XDG_CONFIG_HOME", home_cl},
            {~c"XDG_DATA_HOME", home_cl},
            {~c"XDG_CACHE_HOME", home_cl}
          ]
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  @doc "Blocks until the Caddy admin API on `port` responds; raises after ~5s."
  def await_caddy_admin!(port), do: wait_for_admin!(port)

  @doc "Blocks until the Caddy admin API on `port` stops responding; raises after ~5s."
  def await_caddy_down!(port, tries \\ 50)
  def await_caddy_down!(_port, 0), do: raise("Caddy admin API still reachable 5s after kill")

  def await_caddy_down!(port, tries) do
    case Req.get("http://localhost:#{port}/config/", retry: false) do
      {:error, _} ->
        :ok

      _ ->
        Process.sleep(100)
        await_caddy_down!(port, tries - 1)
    end
  end

  @doc """
  Creates and returns a fresh temporary directory suitable for use as
  Still's `:applications_dir`. Caller is responsible for cleanup via
  `File.rm_rf!/1`.
  """
  def fresh_applications_dir do
    dir = Path.join(System.tmp_dir!(), "still-apps-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Creates and returns a fresh temporary directory for artifact storage.
  Caller is responsible for cleanup via `File.rm_rf!/1`.
  """
  def fresh_artifacts_dir do
    dir = Path.join(System.tmp_dir!(), "still-artifacts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp override_env!(caddy, apps_dir, artifacts_dir) do
    keys = [
      :applications_dir,
      :artifacts_dir,
      :artifact_base_url,
      :artifact_req_options,
      :caddy_req_options,
      :caddy_admin_url,
      :health_req_options
    ]

    original = Map.new(keys, fn key -> {key, Application.get_env(:still, key)} end)

    Application.put_env(:still, :applications_dir, apps_dir)
    Application.put_env(:still, :artifacts_dir, artifacts_dir)
    Application.put_env(:still, :artifact_base_url, "http://localhost:#{caddy.internal_port}")
    Application.put_env(:still, :artifact_req_options, [])
    Application.put_env(:still, :caddy_req_options, [])
    Application.put_env(:still, :caddy_admin_url, "http://localhost:#{caddy.admin_port}")
    Application.put_env(:still, :health_req_options, retry: false)

    original
  end

  defp restore_env!(original) do
    Enum.each(original, fn {key, value} ->
      if is_nil(value) do
        Application.delete_env(:still, key)
      else
        Application.put_env(:still, key, value)
      end
    end)
  end

  @doc """
  Returns a free TCP port on the loopback interface. Used by integration
  tests that need to reserve ports for blue/green app slots.
  """
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wait_for_admin!(port, tries \\ 50)

  defp wait_for_admin!(_port, 0) do
    raise "Caddy admin API did not come up within 5s"
  end

  defp wait_for_admin!(port, tries) do
    case Req.get("http://localhost:#{port}/config/", retry: false) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      _ ->
        Process.sleep(100)
        wait_for_admin!(port, tries - 1)
    end
  end

  @doc """
  Starts a peer BEAM node running `:still` in `:agent` mode, configured to
  share the current test context's `applications_dir` and Caddy instance.

  The peer connects back to the test's node via Erlang distribution so
  `GenServer.call({Still.Agent.DeploymentManager, peer_node}, ...)` works
  from the test process. Returns `%{pid: peer_pid, node: node_name}`.

  Tests are responsible for calling `stop_agent_peer!/1` on teardown
  (usually via `on_exit/1`).
  """
  def start_agent_peer!(ctx) do
    %{applications_dir: apps_dir, caddy: caddy} = ctx

    unless Node.alive?() do
      raise "Erlang distribution is not running — check test_helper.exs"
    end

    peer_name = :"still_agent_#{System.unique_integer([:positive])}"

    {:ok, peer, peer_node} =
      :peer.start(%{
        name: peer_name,
        host: ~c"127.0.0.1",
        args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie())]
      })

    :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    :erpc.call(peer_node, Application, :put_env, [:still, :mode, :agent])
    :erpc.call(peer_node, Application, :put_env, [:still, :controller_node, Node.self()])
    :erpc.call(peer_node, Application, :put_env, [:still, :applications_dir, apps_dir])

    :erpc.call(peer_node, Application, :put_env, [
      :still,
      :caddy_admin_url,
      "http://localhost:#{caddy.admin_port}"
    ])

    :erpc.call(peer_node, Application, :put_env, [:still, :caddy_req_options, []])
    :erpc.call(peer_node, Application, :put_env, [:still, :health_req_options, []])
    :erpc.call(peer_node, Application, :put_env, [:still, :artifact_req_options, []])

    if server_id = Map.get(ctx, :server_id) do
      :erpc.call(peer_node, Application, :put_env, [:still, :server_id, server_id])
    end

    {:ok, _} = :erpc.call(peer_node, Application, :ensure_all_started, [:still])

    %{pid: peer, node: peer_node}
  end

  @doc "Stops a peer previously started with `start_agent_peer!/1`."
  def stop_agent_peer!(%{pid: pid}), do: :peer.stop(pid)

  @doc """
  Starts a fully self-contained agent peer: its own Caddy instance on
  free ports, its own `applications_dir` temp directory, and its own BEAM
  with `:still` running in `:agent` mode. Returns a map suitable for
  `stop_isolated_agent_peer!/1`.

  Use this when a test needs multiple independent peers (e.g., rolling
  deploy across multiple hosts) and cannot share Caddy or filesystem
  state between them.

  ## Options

    * `:server_id` — if set, the peer's `NodeConnector` auto-announces to
      `Still.AgentConnectionManager` on the controller node with this id
      once distribution is up. Tests that drive the `Orchestrator` should
      use this so they don't have to call `agent_connected/1` manually.
  """
  def start_isolated_agent_peer!(opts \\ []) do
    caddy = start_caddy!()
    apps_dir = fresh_applications_dir()

    ctx = %{caddy: caddy, applications_dir: apps_dir}
    ctx = if id = Keyword.get(opts, :server_id), do: Map.put(ctx, :server_id, id), else: ctx

    peer = start_agent_peer!(ctx)
    Map.merge(peer, %{caddy: caddy, applications_dir: apps_dir})
  end

  @doc "Tears down a peer started with `start_isolated_agent_peer!/0`."
  def stop_isolated_agent_peer!(%{caddy: caddy, applications_dir: apps_dir} = peer) do
    stop_agent_peer!(peer)
    stop_caddy!(caddy)
    File.rm_rf!(apps_dir)
    :ok
  end

  @doc """
  Tears down systemd state for an application created by an integration test:
  stops both slot instances, stops the parent slice that systemd auto-creates
  for templated units, removes the unit file, and runs `daemon-reload`. All
  commands are idempotent — "not loaded" or "already stopped" errors are
  ignored so tests can safely call this in both `setup` and `on_exit`.

  The slice name uses systemd's `\\x2d` escape for dashes inside the app
  name (dashes collide with systemd's slice hierarchy separator).
  """
  def cleanup_systemd_units(application) when is_binary(application) do
    for slot <- ["blue", "green"] do
      System.cmd("systemctl", ["stop", "#{application}@#{slot}"], stderr_to_stdout: true)
    end

    slice = "system-" <> String.replace(application, "-", "\\x2d") <> ".slice"
    System.cmd("systemctl", ["stop", slice], stderr_to_stdout: true)

    File.rm("/etc/systemd/system/#{application}@.service")
    System.cmd("systemctl", ["daemon-reload"], stderr_to_stdout: true)
    :ok
  end

  # six:ignore:stop
end
