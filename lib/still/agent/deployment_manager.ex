defmodule Still.Agent.DeploymentManager do
  @moduledoc """
  The agent's deploy state machine.

  A deploy is a sequence of named steps (download, unpack, symlink, start,
  health-check, switch, stop-old, cleanup) plus pre_deploy/release/post_deploy
  hook positions. The release hook sits between symlink and start so it runs
  against the new release files but before any process is started — the
  canonical home for database migrations. The exact step list depends on the
  application type — `:static_site` skips start/health-check/stop-old (and
  therefore the release hook) because no process is involved.

  Apps run as a templated systemd unit, one instance per blue/green slot. The
  unit sources its environment from a per-slot file holding `PORT`,
  `STILL_APPLICATION`, `STILL_TARGET_SLOT`, `STILL_NODE_HOST`, and
  `STILL_RELEASE_VERSION` (all owned by Still), followed by the app's own
  env_vars. Still does not set `RELEASE_NODE`; it emits the slot so a
  distributed release can build a per-slot node name in its own `env.sh` and
  keep blue and green off the same Erlang node name while both are briefly
  live during a flip.

  This module owns the state machine plumbing and the step body
  implementations. Step bodies shell out to real tools (`curl`, `tar`,
  `systemctl`) and call the Caddy admin API — they are proven end-to-end by
  `@tag :integration` tests against real host tools, not unit tests.

  Tests inject a custom step provider via the `:step_provider` start option
  so the state machine can be exercised end-to-end without touching any of
  the real step bodies.
  """

  use GenServer

  require Logger

  alias Still.Agent.ApplicationState
  alias Still.Agent.CaddyManager
  alias Still.Agent.HealthMonitor
  alias Still.Agent.NodeConnector
  alias Still.Agent.StatePersistence
  alias Still.Agent.Systemd
  alias Still.Caddy.Config, as: CaddyConfig
  alias Still.CaddyBootstrap

  @doc """
  Starts the DeploymentManager GenServer and registers it under the module name.

  Optional: `:step_provider` is a 1-arity function that maps an application
  type atom to a list of `{step_name, step_fn}` tuples. Defaults to
  `&default_steps_for/1`.
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers a deploy. Blocks until the deploy completes (or fails) and
  returns `{:ok, version}` or `{:error, %{step:, reason:}}`.
  """
  def deploy(spec) when is_map(spec) do
    GenServer.call(__MODULE__, {:deploy, spec}, :infinity)
  end

  @doc """
  Rolls the application back to its previous version. The caller provides
  a deploy-shaped spec with the application's current config (ports,
  exec_command, health_check, etc.); the target `version` is read from the
  agent's on-disk state — any `:version` field on the passed spec is
  replaced.

  Returns `{:ok, previous_version}` on success, `{:error, :no_previous_version}`
  if state is missing or there is nothing to roll back to, or
  `{:error, %{step:, reason:}}` if a rollback step fails.
  """
  def rollback(spec) when is_map(spec) do
    GenServer.call(__MODULE__, {:rollback, spec}, :infinity)
  end

  @doc """
  Rebuilds the application's serving Caddy route from its currently-active
  slot and the `domain`/`path_prefix` in `spec` — no artifact staging, no
  slot flip, no hooks. Used when an app's routing fields change between
  deploys.

  `spec` carries `application`, `type`, `domain`, and `path_prefix`.
  Returns `{:ok, :reconciled}` when the route was rewritten, `{:ok, :noop}`
  when the app has no active deployment yet (the next deploy picks up the
  new routing), or `{:error, reason}` if Caddy rejects the change.
  """
  def reconcile_route(spec) when is_map(spec) do
    GenServer.call(__MODULE__, {:reconcile_route, spec}, :infinity)
  end

  @impl true
  def init(opts) when is_list(opts) do
    step_provider = Keyword.get(opts, :step_provider, &default_steps_for/1)

    rollback_step_provider =
      Keyword.get(opts, :rollback_step_provider, &default_rollback_steps_for/1)

    {:ok,
     %{
       step_provider: step_provider,
       rollback_step_provider: rollback_step_provider
     }}
  end

  @impl true
  def handle_call({:deploy, spec}, _from, state) when is_map(state) do
    steps = state.step_provider.(spec.type)

    case build_context(spec) do
      {:ok, context} ->
        case run_steps(steps, context) do
          {:ok, ctx} ->
            {:reply, {:ok, ctx.spec.version}, state}

          {:error, _} = error ->
            {:reply, stop_target_on_health_failure(error, context, state), state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:rollback, spec}, _from, state) when is_map(state) do
    case build_rollback_context(spec) do
      {:ok, context} ->
        steps = state.rollback_step_provider.(spec.type)

        case run_steps(steps, context) do
          {:ok, ctx} ->
            {:reply, {:ok, ctx.spec.version}, state}

          {:error, _} = error ->
            {:reply, stop_target_on_health_failure(error, context, state), state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:reconcile_route, spec}, _from, state) when is_map(state) do
    {:reply, reconcile_route_now(spec), state}
  end

  @doc """
  Runs a list of `{step_name, step_fn}` tuples sequentially against an
  initial context, threading the context through each step. Halts on the
  first `{:error, reason}` and returns `{:error, %{step: step_name, reason: reason}}`.

  Each `step_fn` is a 1-arity function that takes the current context map
  and returns either `{:ok, new_ctx}` or `{:error, reason}`.
  """
  def run_steps(steps, ctx) when is_list(steps) and is_map(ctx) do
    Enum.reduce(steps, {:ok, ctx}, fn
      _step, {:error, _} = failed ->
        failed

      {name, step_fn}, {:ok, current_ctx} ->
        case step_fn.(current_ctx) do
          {:ok, new_ctx} -> {:ok, new_ctx}
          {:error, reason} -> {:error, %{step: name, reason: reason}}
        end
    end)
  end

  # A deploy/rollback that fails its health check has just started the target
  # slot, which is now crash-looping or refusing connections and will keep
  # spamming the journal until the next deploy reclaims it — so stop it. Other
  # failed steps either ran before the slot was started (nothing to stop) or
  # after it went healthy (switch/cleanup — leave it for a retry), so only the
  # health-check failure triggers the stop. The stop action is injectable so
  # unit tests don't shell out to systemctl; production uses default_stop_target/2.
  #
  # The deployment-logs plan captures the unit's journal just *before* this stop
  # so the crash reason survives — capture-then-stop. This is the stop half.
  defp stop_target_on_health_failure({:error, %{step: :health_checking}} = error, ctx, state) do
    stop_target = Map.get(state, :stop_target, &default_stop_target/2)
    stop_target.(ctx.spec.application, ctx.target_slot)
    error
  end

  defp stop_target_on_health_failure(error, _ctx, _state), do: error

  @doc """
  Returns the default step list for the given application type — the
  production step provider used when no `:step_provider` option is passed
  to `start_link/1`.

  `:elixir_release` and `:process` share the full lifecycle (download →
  unpack → symlink → start → health-check → switch → stop-old → cleanup
  with pre/post hooks). `:static_site` skips the start, health-check, and
  stop-old steps that don't apply to file-served apps.
  """
  def default_steps_for(:elixir_release) do
    [
      {:pre_deploy, &pre_deploy_hook/1},
      {:downloading, &download/1},
      {:unpacking, &unpack/1},
      {:symlinking, &symlink/1},
      {:release, &release_hook/1},
      {:starting, &start/1},
      {:health_checking, &health_check/1},
      {:switching, &switch_caddy/1},
      {:monitoring, &update_health_monitor/1},
      {:draining, &drain/1},
      {:stopping_old, &stop_old/1},
      {:cleanup, &cleanup/1},
      {:post_deploy, &post_deploy_hook/1}
    ]
  end

  def default_steps_for(:process) do
    default_steps_for(:elixir_release)
  end

  def default_steps_for(:static_site) do
    [
      {:pre_deploy, &pre_deploy_hook/1},
      {:downloading, &download/1},
      {:unpacking, &unpack/1},
      {:symlinking, &symlink/1},
      {:switching, &switch_caddy/1},
      {:cleanup, &cleanup/1},
      {:post_deploy, &post_deploy_hook/1}
    ]
  end

  @doc """
  Returns the rollback step list for the given application type.

  Rollback reuses the on-disk release from the previous slot, so it skips
  download/unpack/symlink. For `:elixir_release` and `:process`, rollback
  restarts the previous slot, health-checks it, flips Caddy back, stops
  the now-inactive slot, and updates `state.json`. For `:static_site`,
  rollback flips Caddy back and updates `state.json` — no process to
  start or stop.
  """
  def default_rollback_steps_for(:elixir_release) do
    [
      {:pre_rollback, &pre_rollback_hook/1},
      {:starting, &start/1},
      {:health_checking, &health_check/1},
      {:switching, &switch_caddy/1},
      {:monitoring, &update_health_monitor/1},
      {:draining, &drain/1},
      {:stopping_old, &stop_old/1},
      {:cleanup, &cleanup/1},
      {:post_rollback, &post_rollback_hook/1}
    ]
  end

  def default_rollback_steps_for(:process) do
    default_rollback_steps_for(:elixir_release)
  end

  def default_rollback_steps_for(:static_site) do
    [
      {:pre_rollback, &pre_rollback_hook/1},
      {:switching, &switch_caddy/1},
      {:cleanup, &cleanup/1},
      {:post_rollback, &post_rollback_hook/1}
    ]
  end

  defp build_context(spec) when is_map(spec) do
    applications_dir = Application.fetch_env!(:still, :applications_dir)
    app_dir = Path.join(applications_dir, spec.application)

    # Every step assumes the app's workspace exists — hooks cd into it,
    # download writes the tarball into it, state.json lives in it. Create
    # it at context-build time so steps don't each have to guard.
    File.mkdir_p!(app_dir)

    with {:ok, current_state} <- read_current_state(spec.application) do
      target_slot = next_slot(current_state)

      {:ok,
       %{
         spec: spec,
         current_state: current_state,
         target_slot: target_slot,
         target_port: port_for_slot(spec, target_slot),
         previous_slot: previous_slot_for(current_state),
         app_dir: app_dir,
         release_dir: Path.join([app_dir, "releases", spec.version]),
         tarball_path: Path.join(app_dir, "#{spec.version}.tar.gz"),
         target_symlink: Path.join(app_dir, "current_#{target_slot}"),
         node_host: node_host()
       }}
    end
  end

  # Host the app advertises its Erlang node on — the STILL_NODE_HOST the agent
  # already runs with. The installer always writes it to /etc/still/still.env
  # in every mode (routable IP with remote agents, 127.0.0.1 standalone), so
  # the fallback only applies when the agent runs outside an install (dev/test).
  defp node_host, do: System.get_env("STILL_NODE_HOST", "127.0.0.1")

  # Distinguish a genuinely-absent state file (first deploy → nil) from a
  # corrupt one. Collapsing both to nil would make a garbled state.json look
  # like a first deploy — next_slot/1 picks :blue and the deploy clobbers
  # whatever is live there. A corrupt file is operator-visible breakage, so
  # fail the deploy loudly instead of silently overwriting a running slot.
  defp read_current_state(application) do
    case StatePersistence.read(application) do
      # six:ignore:next
      {:ok, state} -> {:ok, state}
      {:error, :not_found} -> {:ok, nil}
      {:error, :corrupted} -> {:error, {:state_unreadable, application}}
    end
  end

  defp build_rollback_context(spec) when is_map(spec) do
    case StatePersistence.read(spec.application) do
      {:ok, %ApplicationState{previous_version: prev}} when not is_nil(prev) ->
        # build_context/1 already returns {:ok, ctx} | {:error, _}.
        build_context(Map.put(spec, :version, prev))

      _ ->
        {:error, :no_previous_version}
    end
  end

  defp reconcile_route_now(spec) do
    case StatePersistence.read(spec.application) do
      {:ok, %ApplicationState{active_slot: slot} = persisted} when is_binary(slot) ->
        case switch_caddy(reconcile_context(spec, persisted)) do
          {:ok, _ctx} -> {:ok, :reconciled}
          {:error, _} = error -> error
        end

      _ ->
        {:ok, :noop}
    end
  end

  # Minimal context for a route-only rebuild: the active slot's port and
  # symlink come from persisted state, the domain/path_prefix from `spec`.
  defp reconcile_context(spec, %ApplicationState{active_slot: slot, active_port: port}) do
    app_dir = Path.join(Application.fetch_env!(:still, :applications_dir), spec.application)

    %{
      spec: spec,
      target_port: port,
      target_symlink: Path.join(app_dir, "current_#{slot}")
    }
  end

  # --- Slot helpers + step bodies ---
  #
  # Everything below is exercised only by the `:integration` and
  # `:integration_root` tagged tests against real tools (curl, tar, Caddy
  # admin API, systemctl). The slot helpers are only reachable through
  # `build_context/1` with a pre-populated state.json and the step bodies
  # invoke real shellouts. Neither can be meaningfully unit-tested without
  # the fake/adapter pattern we deliberately rejected; see
  # feedback_integration_over_fakes.md.

  # six:ignore:start

  defp next_slot(nil), do: :blue
  defp next_slot(%ApplicationState{active_slot: "blue"}), do: :green
  defp next_slot(%ApplicationState{active_slot: "green"}), do: :blue
  defp next_slot(%ApplicationState{active_slot: nil}), do: :blue

  defp port_for_slot(%{type: :static_site}, _slot), do: nil
  defp port_for_slot(spec, :blue), do: spec.port_blue
  defp port_for_slot(spec, :green), do: spec.port_green

  defp previous_slot_for(nil), do: nil
  defp previous_slot_for(%ApplicationState{active_slot: "blue"}), do: :blue
  defp previous_slot_for(%ApplicationState{active_slot: "green"}), do: :green
  defp previous_slot_for(_), do: nil

  defp pre_deploy_hook(ctx) when is_map(ctx), do: run_hook(:pre_deploy, ctx)
  defp release_hook(ctx) when is_map(ctx), do: run_hook(:release, ctx)
  defp post_deploy_hook(ctx) when is_map(ctx), do: run_hook(:post_deploy, ctx)
  defp pre_rollback_hook(ctx) when is_map(ctx), do: run_hook(:pre_rollback, ctx)
  defp post_rollback_hook(ctx) when is_map(ctx), do: run_hook(:post_rollback, ctx)

  # Look up the hook for this event in the deploy spec and either run it or
  # fall through to `{:ok, ctx}`. Hooks are optional — absence is not an
  # error; the step just becomes a no-op so every applicable step still
  # shows up in the deploy progress trail at a fixed position.
  defp run_hook(event, ctx) do
    case Map.get(ctx.spec.hooks || %{}, event) do
      nil -> {:ok, ctx}
      hook -> execute_hook(event, hook, ctx)
    end
  end

  # Covered by the static_site hook integration test which runs the real
  # `timeout` + `bash` shellout. Stubbing System.cmd here would require
  # the adapter/fake pattern we've deliberately rejected — see
  # feedback_integration_over_fakes.md.
  defp execute_hook(event, %{script: script, timeout_ms: timeout_ms}, ctx) do
    env = hook_env(ctx)
    seconds = max(div(timeout_ms, 1000), 1)

    args = [
      "--kill-after=5",
      "--signal=TERM",
      "#{seconds}s",
      "bash",
      "-c",
      script
    ]

    case System.cmd("timeout", args, env: env, stderr_to_stdout: true, cd: ctx.app_dir) do
      {_, 0} ->
        {:ok, ctx}

      {_, 124} ->
        {:error, "#{event} hook timed out after #{timeout_ms}ms"}

      {_, 137} ->
        {:error, "#{event} hook killed (SIGKILL) after exceeding grace period"}

      {output, code} ->
        {:error, "#{event} hook exit #{code}: #{String.trim(output)}"}
    end
  end

  # Environment exposed to every hook. Still-prefixed vars give the hook
  # enough context to know what it's operating on; the application's own
  # env_vars are merged in so hooks can run the same commands with the
  # same env as the deployed process.
  defp hook_env(ctx) do
    release_dir =
      case ctx.spec.type do
        :static_site -> ctx.target_symlink
        _ -> ctx.release_dir
      end

    still_env = %{
      "STILL_APPLICATION" => ctx.spec.application,
      "STILL_RELEASE_VERSION" => ctx.spec.version,
      "STILL_TYPE" => Atom.to_string(ctx.spec.type),
      "STILL_APP_DIR" => ctx.app_dir,
      "STILL_RELEASE_DIR" => release_dir,
      "STILL_TARGET_SLOT" => Atom.to_string(ctx.target_slot)
    }

    app_env = ctx.spec.env_vars || %{}

    still_env
    |> Map.merge(app_env)
    |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp download(ctx) when is_map(ctx) do
    provider = Map.get(ctx.spec, :artifact_provider, Still.Artifact.Provider.URL)

    case provider.download(ctx.spec, ctx.tarball_path) do
      :ok -> {:ok, ctx}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unpack(ctx) when is_map(ctx) do
    File.rm_rf!(ctx.release_dir)
    File.mkdir_p!(ctx.release_dir)

    args = ["-xzf", ctx.tarball_path, "-C", ctx.release_dir]

    case System.cmd("tar", args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, ctx}
      {output, code} -> {:error, "tar exit #{code}: #{String.trim(output)}"}
    end
  end

  defp symlink(ctx) when is_map(ctx) do
    File.rm_rf!(ctx.target_symlink)

    case File.ln_s(ctx.release_dir, ctx.target_symlink) do
      :ok ->
        {:ok, ctx}

      {:error, reason} ->
        {:error, "symlink #{ctx.target_symlink} -> #{ctx.release_dir}: #{inspect(reason)}"}
    end
  end

  defp switch_caddy(ctx) when is_map(ctx) do
    with {:ok, config} <- CaddyManager.get_config(),
         {:ok, new_config} <- put_app_route(config, build_app_route(ctx)),
         :ok <- CaddyManager.load_config(new_config) do
      {:ok, ctx}
    end
  end

  defp put_app_route(config, %{"@id" => _} = new_route) do
    case get_in(config, ["apps", "http", "servers", "still", "routes"]) do
      nil ->
        {:error, :caddy_server_not_provisioned}

      routes when is_list(routes) ->
        updated = CaddyBootstrap.with_catchall_last(upsert_route(routes, new_route))
        {:ok, put_in(config, ["apps", "http", "servers", "still", "routes"], updated)}
    end
  end

  defp upsert_route(routes, %{"@id" => id} = new_route) do
    case Enum.find_index(routes, &(Map.get(&1, "@id") == id)) do
      nil -> routes ++ [new_route]
      idx -> List.replace_at(routes, idx, new_route)
    end
  end

  # six:ignore:stop

  @doc """
  Builds the Caddy route JSON for an application. The returned map has a
  stable `@id` of `still_app_<application>` so it can be upserted into the
  server's route list without disturbing other apps.

  The route matches on the app's `domain` (required) and optional
  `path_prefix`; without a host matcher, multiple apps sharing one Caddy
  would collide on the first-match-wins rule. `:elixir_release` and
  `:process` get a `reverse_proxy` handle pointed at the active
  blue/green port; `:static_site` gets a `subroute` that serves files
  from the active release dir with a `try_files → /index.html` fallback
  so SPA deep links don't 404.
  """
  def build_app_route(ctx) when is_map(ctx) do
    CaddyConfig.route(
      id: "still_app_#{ctx.spec.application}",
      match: [match_for(ctx)],
      handle: handle_for(ctx),
      terminal: true
    )
  end

  defp match_for(ctx) do
    path =
      case Map.get(ctx.spec, :path_prefix) do
        nil -> nil
        "" -> nil
        prefix when is_binary(prefix) -> [prefix <> "*"]
      end

    CaddyConfig.match(host: [ctx.spec.domain], path: path)
  end

  defp handle_for(%{spec: spec} = ctx) do
    if Map.get(spec, :maintenance, false) do
      [CaddyConfig.maintenance_response(Map.get(spec, :maintenance_message))]
    else
      serve_handle(ctx)
    end
  end

  defp serve_handle(%{spec: %{type: :static_site}} = ctx) do
    CaddyConfig.static_site_handle(root: ctx.target_symlink)
  end

  defp serve_handle(%{spec: %{type: type}} = ctx) when type in [:elixir_release, :process] do
    [CaddyConfig.reverse_proxy(dial: "localhost:#{ctx.target_port}")]
  end

  @doc """
  Whether a slot's systemd `ActiveState` means the unit has given up — the
  signal `poll_health/4` uses to fail a deploy fast instead of polling to the
  full HTTP deadline.

  Only `"failed"` qualifies. A boot crash-loop trips the unit's
  `StartLimitBurst` and latches `ActiveState` to `"failed"`, which is
  permanent until the next deploy's `reset-failed`. The transient
  `"activating"` the unit cycles through during each `RestartSec` pause must
  NOT abort an otherwise-slow-but-healthy boot, and a `nil` state (systemd
  unreachable) falls through to the normal timeout.
  """
  def unit_failed?("failed"), do: true
  def unit_failed?(_active_state), do: false

  # six:ignore:start

  defp cleanup(ctx) when is_map(ctx) do
    new_state = %ApplicationState{
      type: Atom.to_string(ctx.spec.type),
      active_slot: Atom.to_string(ctx.target_slot),
      active_port: active_port_for(ctx),
      current_version: ctx.spec.version,
      previous_version: previous_version(ctx.current_state),
      last_health_check_at: nil
    }

    case StatePersistence.write(ctx.spec.application, new_state) do
      :ok ->
        File.rm_rf!(ctx.tarball_path)
        report_state(ctx.spec.application, new_state)
        {:ok, ctx}

      {:error, reason} ->
        {:error, "state write failed: #{inspect(reason)}"}
    end
  end

  # Push the new application state to the controller's
  # AgentConnectionManager so /api/status/* reflects it immediately
  # without waiting for the next reconnect/announce. No-op when
  # NodeConnector isn't running (test environments that exercise the
  # state machine in isolation).
  defp report_state(application_name, %ApplicationState{} = new_state) do
    if Process.whereis(NodeConnector) do
      NodeConnector.report_application_state(application_name, new_state)
    end

    :ok
  end

  defp update_health_monitor(ctx) when is_map(ctx) do
    if Process.whereis(HealthMonitor) do
      :ok =
        HealthMonitor.register(ctx.spec.application, %{
          port: ctx.target_port,
          path: ctx.spec.health_check.path,
          interval_ms: ctx.spec.health_check.interval_ms,
          timeout_ms: 2_000,
          failure_threshold: 3
        })
    end

    {:ok, ctx}
  end

  defp active_port_for(%{spec: %{type: :static_site}}), do: nil
  defp active_port_for(%{target_slot: :blue, spec: %{port_blue: port}}), do: port
  defp active_port_for(%{target_slot: :green, spec: %{port_green: port}}), do: port

  defp previous_version(nil), do: nil
  defp previous_version(%ApplicationState{current_version: v}), do: v

  defp start(ctx) when is_map(ctx) do
    with :ok <- write_slot_env_file(ctx),
         :ok <- write_systemd_unit(ctx),
         :ok <- systemd_daemon_reload(),
         :ok <- restart_slot(ctx.spec.application, ctx.target_slot) do
      {:ok, ctx}
    end
  end

  # Bring the target slot up with `restart`, not `start`. A redeploy can target
  # a slot whose unit is still active — e.g. a prior deploy that failed its
  # health check left the old BEAM running — and `systemctl start` on an
  # already-active unit is a no-op, so it would keep serving the stale release
  # even though the symlink now points at the new one. `restart` re-execs it.
  # `reset-failed` first clears any crash-loop `failed` state (the unit's
  # StartLimitBurst) so the restart isn't refused; its own result is irrelevant.
  defp restart_slot(application, slot) do
    _ = systemctl(:"reset-failed", application, slot)
    systemctl(:restart, application, slot)
  end

  defp health_check(ctx) when is_map(ctx) do
    url = "http://localhost:#{ctx.target_port}#{ctx.spec.health_check.path}"
    interval = ctx.spec.health_check.interval_ms
    timeout = ctx.spec.health_check.deadline_ms
    deadline = System.monotonic_time(:millisecond) + timeout

    poll_health(url, interval, deadline, ctx)
  end

  defp poll_health(url, interval, deadline, ctx) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :health_check_timeout}
    else
      case Req.get(url, retry: false, receive_timeout: 2_000) do
        {:ok, %{status: status}} when status in 200..299 ->
          {:ok, ctx}

        _ ->
          fail_fast_or_retry(url, interval, deadline, ctx)
      end
    end
  end

  # The probe failed. Before sleeping for another interval, ask systemd whether
  # the unit has given up: a boot crash-loop trips StartLimitBurst and latches
  # ActiveState to "failed", at which point the port will never come up. Fail
  # fast with a truthful reason instead of grinding to the misleading
  # full-deadline timeout.
  defp fail_fast_or_retry(url, interval, deadline, ctx) do
    %{active_state: active_state} = Systemd.info_for(ctx.spec.application, ctx.target_slot)

    if unit_failed?(active_state) do
      {:error, :app_crash_looped}
    else
      Process.sleep(interval)
      poll_health(url, interval, deadline, ctx)
    end
  end

  defp stop_old(ctx) when is_map(ctx) do
    cond do
      ctx.spec.type == :static_site ->
        {:ok, ctx}

      is_nil(ctx.previous_slot) ->
        {:ok, ctx}

      true ->
        # Best-effort: switch_caddy already moved traffic to the new slot and
        # cleanup records it next, so a failure to stop the OLD slot must not
        # abort the deploy — that would halt before cleanup and leave state.json
        # naming the old slot while Caddy serves the new one. Log and continue;
        # the orphaned unit is reclaimed (restarted) by the next deploy.
        case systemctl(:stop, ctx.spec.application, ctx.previous_slot) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "stop_old: #{ctx.spec.application}@#{ctx.previous_slot} did not stop: #{reason}"
            )
        end

        {:ok, ctx}
    end
  end

  # Best-effort stop of a target slot whose deploy/rollback failed its health
  # check (see stop_target_on_health_failure/3). The deploy already failed, so a
  # failure to stop must not raise — log and move on; the next deploy reclaims it.
  defp default_stop_target(application, slot) do
    case systemctl(:stop, application, slot) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("stop_failed_target: #{application}@#{slot} did not stop: #{reason}")
        :ok
    end
  end

  # Drain the old slot: after `switch_caddy` has atomically moved Caddy's
  # upstream to the new slot, pause for `drain_ms` so any HTTP requests
  # that Caddy had already forwarded to the old BEAM have time to finish
  # responding before `stop_old` signals the BEAM to shut down. Caddy's
  # reverse_proxy handles in-flight requests through the old handler
  # naturally; this pause just gives those in-flight requests their own
  # window before shutdown pressure kicks in.
  defp drain(ctx) when is_map(ctx) do
    drain_ms = Map.get(ctx.spec, :drain_ms) || 0
    if drain_ms > 0, do: Process.sleep(drain_ms)
    {:ok, ctx}
  end

  # --- systemd helpers ---

  # six:ignore:stop

  @doc """
  Ordered `{key, value}` env for a slot's systemd EnvironmentFile:
  Still-owned context first, then the app's `env_vars`.

  Still emits `STILL_APPLICATION`, `STILL_TARGET_SLOT`, `STILL_NODE_HOST`, and
  `STILL_RELEASE_VERSION` (plus `PORT`) but does not set `RELEASE_NODE` — a
  release owns its own node name. `STILL_TARGET_SLOT` is the one thing the
  release can't derive itself; a distributed release composes a per-slot
  `RELEASE_NODE` from it (and `STILL_NODE_HOST`) in `rel/env.sh.eex` so blue
  and green don't share an Erlang node name while both are briefly live during
  a flip.
  """
  def slot_env_vars(ctx) when is_map(ctx) do
    still_vars = [
      {"PORT", ctx.target_port},
      {"STILL_APPLICATION", ctx.spec.application},
      {"STILL_TARGET_SLOT", Atom.to_string(ctx.target_slot)},
      {"STILL_NODE_HOST", ctx.node_host},
      {"STILL_RELEASE_VERSION", ctx.spec.version}
    ]

    still_vars ++ Enum.to_list(ctx.spec.env_vars || %{})
  end

  # six:ignore:start

  defp write_slot_env_file(ctx) do
    dir = Path.join(ctx.app_dir, "slots")
    File.mkdir_p!(dir)

    body = Enum.map_join(slot_env_vars(ctx), "\n", fn {k, v} -> "#{k}=#{v}" end)

    case File.write(Path.join(dir, "#{ctx.target_slot}.env"), body <> "\n") do
      :ok -> :ok
      {:error, reason} -> {:error, "slot env file write failed: #{inspect(reason)}"}
    end
  end

  defp write_systemd_unit(ctx) do
    content = render_unit_file(ctx)
    path = Path.join(systemd_unit_dir(), "#{ctx.spec.application}@.service")

    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "systemd unit write failed: #{inspect(reason)}"}
    end
  end

  defp render_unit_file(ctx) do
    spec = ctx.spec
    user = Map.get(spec, :user)
    exec_start_pre = Map.get(spec, :exec_start_pre)
    exec_stop = Map.get(spec, :exec_stop)
    stop_timeout_ms = Map.get(spec, :stop_timeout_ms)

    service_lines =
      [
        "Type=simple",
        "WorkingDirectory=#{ctx.app_dir}/current_%i",
        "EnvironmentFile=#{ctx.app_dir}/slots/%i.env",
        user && "User=#{user}",
        exec_start_pre && "ExecStartPre=#{resolve_exec_command(exec_start_pre, ctx)}",
        "ExecStart=#{resolve_exec_command(spec.exec_command, ctx)}",
        exec_stop && "ExecStop=#{resolve_exec_command(exec_stop, ctx)}",
        stop_timeout_ms && "TimeoutStopSec=#{div(stop_timeout_ms, 1000)}",
        "Restart=always",
        # 2s restart backoff — systemd's 100ms default lets a boot crash-loop
        # hammer ~10x/sec and trip StartLimitBurst before the cause is readable.
        "RestartSec=2s"
      ]
      |> Enum.reject(&is_nil/1)

    """
    [Unit]
    Description=Still: #{spec.application} (%i)
    After=network.target
    StartLimitBurst=5
    StartLimitIntervalSec=60

    [Service]
    #{Enum.join(service_lines, "\n")}

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp resolve_exec_command(command, ctx) do
    if String.starts_with?(command, "/") do
      command
    else
      "#{ctx.app_dir}/current_%i/#{command}"
    end
  end

  defp systemd_daemon_reload do
    case System.cmd("systemctl", ["daemon-reload"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "systemctl daemon-reload exit #{code}: #{String.trim(output)}"}
    end
  end

  defp systemctl(action, application, slot) do
    instance = "#{application}@#{slot}"

    case System.cmd("systemctl", [Atom.to_string(action), instance], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        {:error, "systemctl #{action} #{instance} exit #{code}: #{String.trim(output)}"}
    end
  end

  defp systemd_unit_dir do
    Application.get_env(:still, :systemd_unit_dir, "/etc/systemd/system")
  end

  # six:ignore:stop
end
