defmodule Still.Agent.ConsoleManager do
  @moduledoc """
  Owns interactive remote-console sessions on an agent server.

  A session spawns the application's own launch command with the trailing
  release subcommand swapped to `remote` (`bin/app start` → `bin/app remote`)
  in a real PTY, with the slot's environment file loaded and the agent's own
  environment excluded. Bytes flow to and from an owner process — typically a
  LiveView on the controller — over Erlang distribution. When the owner dies,
  the PTY process group is killed.

  Sessions are bounded: per-user and per-agent concurrency caps and an open
  rate limit are enforced before spawning; idle and absolute timeouts reap
  abandoned sessions; output is coalesced, rate-capped, and dropped with a
  visible marker rather than buffered without bound, so a runaway console
  cannot starve the distribution link that also carries deploys. All limits
  are overridable via the `:still, :console` application config.
  """

  use GenServer

  alias Still.Agent.StatePersistence

  @release_subcommands ~w(start start_iex daemon daemon_iex)
  @child_path "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  @truncation_marker "\r\n\e[33m[output truncated]\e[0m\r\n"

  @defaults [
    term: "xterm-256color",
    idle_timeout_ms: 15 * 60_000,
    absolute_timeout_ms: 60 * 60_000,
    max_sessions_per_app_user: 2,
    max_sessions: 8,
    max_opens_per_minute: 10,
    input_window_ms: 1000,
    output_flush_ms: 25,
    output_rate_bytes_per_sec: 5_000_000,
    output_buffer_max_bytes: 1_048_576,
    input_rate_bytes_per_sec: 65_536
  ]

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Opens a console session. Called across the mesh as
  `GenServer.call({ConsoleManager, agent_node}, {:open, params}, timeout)`.

  `params` requires `:application`, `:slot`, `:exec_command`, `:owner`,
  `:rows`, and `:cols`; `:exec_console` optionally overrides the derived
  console command for launch commands the subcommand swap can't handle;
  `:user_id` attributes the session for concurrency caps and rate limiting.

  Returns `{:ok, session_id}` or `{:error, reason}` where reason is
  `:not_deployed`, `:slot_not_active`, `:needs_exec_console`,
  `:session_limit`, `:agent_session_limit`, or `:rate_limited`. The owner
  process then receives `{:console_output, session_id, data}`,
  `{:console_timeout, session_id, :idle | :absolute}` when a timeout fires,
  and `{:console_exit, session_id, status}` when the console process exits.
  """
  def open(node, params) when is_map(params) do
    GenServer.call({__MODULE__, node}, {:open, params}, 30_000)
  end

  @doc "Sends keyboard input to the session's PTY."
  def input(node, session_id, data)
      when is_atom(node) and is_integer(session_id) and is_binary(data) do
    GenServer.cast({__MODULE__, node}, {:input, session_id, data})
  end

  @doc "Resizes the session's PTY."
  def resize(node, session_id, rows, cols)
      when is_atom(node) and is_integer(session_id) and is_integer(rows) and is_integer(cols) do
    GenServer.cast({__MODULE__, node}, {:resize, session_id, rows, cols})
  end

  @doc "Closes the session, killing the console process group."
  def close(node, session_id) when is_atom(node) and is_integer(session_id) do
    GenServer.cast({__MODULE__, node}, {:close, session_id})
  end

  @doc """
  Derives the console command from a resolved launch command by replacing the
  trailing release subcommand (`start`, `start_iex`, `daemon`, `daemon_iex`)
  with `remote`. Returns `{:error, :needs_exec_console}` when the last token
  is not a bare release subcommand — quoted or shell-wrapped launch commands
  must set `exec_console` instead.
  """
  def derive_console_command(exec_command) when is_binary(exec_command) do
    tokens = String.split(exec_command)

    case List.last(tokens) do
      last when last in @release_subcommands ->
        {:ok, tokens |> List.replace_at(-1, "remote") |> Enum.join(" ")}

      _ ->
        {:error, :needs_exec_console}
    end
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{sessions: %{}, opens: %{}}}
  end

  @impl true
  def handle_call({:open, params}, _from, state) when is_map(state) do
    state = record_open_attempt(state, params[:user_id])

    with :ok <- check_limits(state, params),
         {:ok, sid, session} <- open_session(params) do
      state = put_in(state.sessions[sid], session)
      emit(:opened, %{active: map_size(state.sessions)}, %{application: params.application})
      {:reply, {:ok, sid}, state}
    else
      {:error, reason} ->
        emit(:rejected, %{count: 1}, %{reason: reason_tag(reason)})
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:input, sid, data}, state) when is_map(state) do
    case state.sessions[sid] do
      nil ->
        {:noreply, state}

      session ->
        session = session |> accept_input(data) |> reset_idle_timer(sid)
        {:noreply, put_in(state.sessions[sid], session)}
    end
  end

  def handle_cast({:resize, sid, rows, cols}, state) when is_map(state) do
    with %{os_pid: os_pid} <- state.sessions[sid], do: :exec.winsz(os_pid, rows, cols)
    {:noreply, state}
  end

  def handle_cast({:close, sid}, state) when is_map(state) do
    case state.sessions[sid] do
      %{exec_pid: exec_pid} ->
        :exec.stop(exec_pid)
        {:noreply, put_in(state.sessions[sid].close_reason, :closed)}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, state) do
    case state.sessions[os_pid] do
      nil -> {:noreply, state}
      session -> {:noreply, put_in(state.sessions[os_pid], buffer_output(session, os_pid, data))}
    end
  end

  def handle_info({:flush, sid}, state) do
    case state.sessions[sid] do
      nil -> {:noreply, state}
      session -> {:noreply, put_in(state.sessions[sid], flush_output(session, sid))}
    end
  end

  def handle_info({:session_timeout, sid, kind}, state) do
    case state.sessions[sid] do
      %{exec_pid: exec_pid, owner: owner} ->
        send(owner, {:console_timeout, sid, kind})
        :exec.stop(exec_pid)
        {:noreply, put_in(state.sessions[sid].close_reason, {:timeout, kind})}

      nil ->
        {:noreply, state}
    end
  end

  # Console process exited (user typed exit, node went away, or :close).
  def handle_info({:DOWN, os_pid, :process, _exec_pid, status}, state)
      when is_integer(os_pid) do
    case Map.pop(state.sessions, os_pid) do
      {nil, _} ->
        {:noreply, state}

      {session, sessions} ->
        drain_output(session, os_pid)
        cancel_session(session)
        emit_reap(session, sessions)
        send(session.owner, {:console_exit, os_pid, status})
        {:noreply, %{state | sessions: sessions}}
    end
  end

  # Owner (controller LiveView) died or the controller node went down.
  def handle_info({:DOWN, ref, :process, _owner, _reason}, state) when is_reference(ref) do
    case Enum.find(state.sessions, fn {_sid, s} -> s.mon_ref == ref end) do
      {sid, session} ->
        :exec.stop(session.exec_pid)
        cancel_session(session)
        sessions = Map.delete(state.sessions, sid)
        emit(:reaped, %{active: map_size(sessions)}, %{cause: :owner_down})
        {:noreply, %{state | sessions: sessions}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- limits ---

  defp record_open_attempt(state, user_id) do
    now = System.monotonic_time(:millisecond)
    recent = for t <- Map.get(state.opens, user_id, []), now - t < 60_000, do: t
    put_in(state.opens[user_id], [now | recent])
  end

  defp check_limits(state, params) do
    user_id = params[:user_id]

    per_app_user =
      Enum.count(state.sessions, fn {_sid, s} ->
        s.application == params.application and s.user_id == user_id
      end)

    cond do
      length(state.opens[user_id]) > config(:max_opens_per_minute) ->
        {:error, :rate_limited}

      map_size(state.sessions) >= config(:max_sessions) ->
        {:error, :agent_session_limit}

      per_app_user >= config(:max_sessions_per_app_user) ->
        {:error, :session_limit}

      true ->
        :ok
    end
  end

  # --- session lifecycle ---

  defp open_session(params) do
    %{application: application, slot: slot, owner: owner} = params
    app_dir = Path.join(Application.fetch_env!(:still, :applications_dir), application)

    with :ok <- validate_slot(application, slot),
         {:ok, command} <- console_command(params, app_dir, slot),
         {:ok, env} <- child_env(app_dir, slot),
         {:ok, exec_pid, os_pid} <-
           spawn_console(command, env, app_dir, slot, params.rows, params.cols) do
      {:ok, os_pid,
       %{
         exec_pid: exec_pid,
         os_pid: os_pid,
         owner: owner,
         mon_ref: Process.monitor(owner),
         application: application,
         slot: slot,
         user_id: params[:user_id],
         close_reason: :exited,
         idle_timer: start_timer(os_pid, :idle, config(:idle_timeout_ms)),
         abs_timer: start_timer(os_pid, :absolute, config(:absolute_timeout_ms)),
         out_buffer: [],
         out_size: 0,
         truncated: false,
         flush_scheduled: false,
         input_window_start: System.monotonic_time(:millisecond),
         input_window_bytes: 0
       }}
    end
  end

  defp start_timer(sid, kind, ms) do
    Process.send_after(self(), {:session_timeout, sid, kind}, ms)
  end

  defp reset_idle_timer(session, sid) do
    Process.cancel_timer(session.idle_timer)
    %{session | idle_timer: start_timer(sid, :idle, config(:idle_timeout_ms))}
  end

  defp cancel_session(session) do
    Process.cancel_timer(session.idle_timer)
    Process.cancel_timer(session.abs_timer)
    Process.demonitor(session.mon_ref, [:flush])
  end

  # --- input (paste-flood cap) ---

  defp accept_input(session, data) do
    now = System.monotonic_time(:millisecond)

    session =
      if now - session.input_window_start >= config(:input_window_ms) do
        %{session | input_window_start: now, input_window_bytes: 0}
      else
        session
      end

    if session.input_window_bytes + byte_size(data) > config(:input_rate_bytes_per_sec) do
      session
    else
      :exec.send(session.os_pid, data)
      %{session | input_window_bytes: session.input_window_bytes + byte_size(data)}
    end
  end

  # --- output (coalesce + rate cap + bounded buffer) ---

  defp buffer_output(session, sid, data) do
    space = config(:output_buffer_max_bytes) - session.out_size

    session =
      cond do
        byte_size(data) <= space ->
          %{
            session
            | out_buffer: [session.out_buffer, data],
              out_size: session.out_size + byte_size(data)
          }

        space > 0 ->
          kept = binary_part(data, 0, space)

          %{
            session
            | out_buffer: [session.out_buffer, kept],
              out_size: session.out_size + space,
              truncated: true
          }

        true ->
          %{session | truncated: true}
      end

    schedule_flush(session, sid)
  end

  defp schedule_flush(%{flush_scheduled: true} = session, _sid), do: session

  defp schedule_flush(session, sid) do
    Process.send_after(self(), {:flush, sid}, config(:output_flush_ms))
    %{session | flush_scheduled: true}
  end

  defp flush_output(session, sid) do
    allowance =
      max(div(config(:output_rate_bytes_per_sec) * config(:output_flush_ms), 1000), 1)

    buffer = IO.iodata_to_binary(session.out_buffer)

    {chunk, rest} =
      case buffer do
        <<chunk::binary-size(allowance), rest::binary>> -> {chunk, rest}
        _ -> {buffer, ""}
      end

    {chunk, session} =
      if session.truncated and rest == "" do
        {chunk <> @truncation_marker, %{session | truncated: false}}
      else
        {chunk, session}
      end

    if chunk != "" do
      send(session.owner, {:console_output, sid, chunk})
      emit(:output, %{bytes: byte_size(chunk)}, %{application: session.application})
    end

    session = %{session | out_buffer: [rest], out_size: byte_size(rest), flush_scheduled: false}
    if rest == "", do: session, else: schedule_flush(session, sid)
  end

  # Forward whatever is still buffered when the console process exits, so the
  # tail of its output (attach failures especially) reaches the owner.
  defp drain_output(session, sid) do
    remainder = IO.iodata_to_binary(session.out_buffer)
    if remainder != "", do: send(session.owner, {:console_output, sid, remainder})
  end

  # --- spawning ---

  # The exec failure for a missing binary happens post-fork inside the child,
  # so :exec.run reports success either way — check up front instead.
  defp spawn_console([exe | _] = command, env, app_dir, slot, rows, cols) do
    if File.exists?(exe) do
      do_spawn_console(command, env, app_dir, slot, rows, cols)
    else
      {:error, {:spawn_failed, :enoent}}
    end
  end

  defp do_spawn_console(command, env, app_dir, slot, rows, cols) do
    case :exec.run(command, [
           {:stdout, self()},
           {:stderr, :stdout},
           :stdin,
           :pty,
           {:winsz, {rows, cols}},
           {:env, env},
           {:cd, Path.join(app_dir, "current_#{slot}")},
           {:group, 0},
           :kill_group,
           {:kill_timeout, 5},
           :monitor
         ]) do
      {:ok, exec_pid, os_pid} ->
        {:ok, exec_pid, os_pid}

      # six:ignore:start
      # erlexec run errors (bad option, port death) are not reproducible
      # without root/portexe manipulation
      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
        # six:ignore:stop
    end
  end

  defp validate_slot(application, slot) do
    case StatePersistence.read(application) do
      {:ok, %{active_slot: active}} ->
        if to_string(active) == to_string(slot), do: :ok, else: {:error, :slot_not_active}

      {:error, _} ->
        {:error, :not_deployed}
    end
  end

  defp console_command(params, app_dir, slot) do
    case params[:exec_console] do
      nil ->
        with {:ok, derived} <- derive_console_command(params.exec_command) do
          {:ok, resolve_command(derived, app_dir, slot)}
        end

      override ->
        {:ok, resolve_command(override, app_dir, slot)}
    end
  end

  # Mirrors the systemd unit's path resolution, with %i substituted directly
  # since the console spawns outside systemd. Returns an argv list — the
  # command is exec'd without a shell, same as systemd's ExecStart=.
  defp resolve_command(command, app_dir, slot) do
    resolved =
      if String.starts_with?(command, "/") do
        command
      else
        "#{app_dir}/current_%i/#{command}"
      end

    resolved
    |> String.replace("%i", to_string(slot))
    |> String.split()
  end

  # The child env is built from scratch (:clear) so the console process never
  # inherits the agent's environment — most importantly the mesh
  # RELEASE_COOKIE. The slot file's own vars (STILL_*, PORT, app env_vars)
  # are what the release's env.sh needs to recompute its node name.
  defp child_env(app_dir, slot) do
    env_path = Path.join([app_dir, "slots", "#{slot}.env"])

    case File.read(env_path) do
      {:ok, body} ->
        slot_vars =
          for line <- String.split(body, "\n", trim: true),
              [k, v] <- [String.split(line, "=", parts: 2)],
              do: {k, v}

        {:ok,
         [
           :clear,
           {"PATH", @child_path},
           {"HOME", console_home!(app_dir)},
           {"TERM", config(:term)},
           {"LANG", "C.UTF-8"}
           | slot_vars
         ]}

      {:error, _} ->
        {:error, :not_deployed}
    end
  end

  # A Still-owned HOME for console sessions whose `.iex.exs` turns on IEx
  # colors. The deployed node has ANSI off by default and a remsh evaluates on
  # that node, so a startup file is the only place to enable colors without
  # touching the running app (`start` never loads `.iex.exs`).
  defp console_home!(app_dir) do
    home = Path.join(app_dir, ".console")
    File.mkdir_p!(home)
    File.write!(Path.join(home, ".iex.exs"), "IEx.configure(colors: [enabled: true])\n")
    home
  end

  defp config(key) do
    Keyword.get(Application.get_env(:still, :console, []), key, @defaults[key])
  end

  # --- telemetry ---
  #
  # Events under `[:still, :console, _]`:
  #   :opened   measurement %{active}  metadata %{application}
  #   :rejected measurement %{count}   metadata %{reason}
  #   :output   measurement %{bytes}   metadata %{application}
  #   :reaped   measurement %{active}  metadata %{cause}
  defp emit(event, measurements, metadata) do
    :telemetry.execute([:still, :console, event], measurements, metadata)
  end

  defp emit_reap(session, remaining) do
    cause =
      case session.close_reason do
        {:timeout, kind} -> :"timeout_#{kind}"
        other -> other
      end

    emit(:reaped, %{active: map_size(remaining)}, %{cause: cause})
  end

  defp reason_tag({:spawn_failed, _}), do: :spawn_failed
  defp reason_tag(reason) when is_atom(reason), do: reason
end
