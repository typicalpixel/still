defmodule Still.IngressReconciler do
  @moduledoc """
  Keeps the controller's local Caddy config in sync with the routing
  registry. Runs only in controller mode — standalone relies on the
  agent-local routes the DeploymentManager writes, and agent mode
  doesn't have the DB rows this process reads from.

  On startup the reconciler runs one pass immediately. After that it
  subscribes to the `fleet:changes` PubSub topic and debounces
  incoming events into a single reconcile pass. Debouncing coalesces
  rapid bursts (e.g. a migration that creates ten applications in a
  row) into one Caddy round trip.

  The reconcile itself:

    1. Reads the current Caddy config via `CaddyManager.get_config/0`.
    2. Builds the desired ingress routes from `Still.Applications.list_routes/0`
       via `Still.Ingress.build_routes/1`.
    3. Drops any existing `still_ingress_*` routes from the current
       Caddy config and appends the newly-built set, preserving all
       non-ingress routes (`still_controller`, agent-local `still_app_*`)
       and keeping the `still_catchall` route last, plus any other
       server fields.
    4. Pushes the new config via `CaddyManager.load_config/1`.

  Caddy is the authoritative validator; if it rejects the config the
  error is logged and the reconciler leaves the state alone, waiting
  for the next event to try again.
  """

  use GenServer

  require Logger

  alias Still.Agent.CaddyManager
  alias Still.Applications
  alias Still.CaddyBootstrap
  alias Still.Events
  alias Still.Ingress

  @default_debounce_ms 500

  @doc """
  Starts the reconciler.

  Options:
    * `:debounce_ms` — how long to wait after the last event before
      running a reconcile pass. Defaults to `#{@default_debounce_ms}`.
      Tests often use a low value or bypass debouncing entirely via
      `reconcile_now/1`.
    * `:caddy_module` — module implementing `get_config/0` and
      `load_config/1`. Defaults to `Still.Agent.CaddyManager`. Tests
      can inject a stub to avoid a live Caddy.
    * `:list_routes` — 0-arity function returning the routing entries.
      Defaults to `&Still.Applications.list_routes/0`. Tests can inject
      a stub to avoid a live DB.
    * `:notifier` — pid that receives `{:ingress_reconciled, result}`
      after every reconcile pass, where `result` is `:ok` or
      `{:error, reason}`. Used by tests to `assert_receive` a
      completion instead of polling. Defaults to `nil` (no notifier).
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Forces an immediate reconcile pass, bypassing debouncing. Synchronous —
  the caller gets `:ok` or `{:error, reason}` reflecting the Caddy push.
  Used by tests and by operators via remote console to force a refresh
  without having to fire a fake event.
  """
  def reconcile_now(server \\ __MODULE__) do
    GenServer.call(server, :reconcile_now)
  end

  @impl true
  def init(opts) when is_list(opts) do
    state = %{
      debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms),
      caddy_module: Keyword.get(opts, :caddy_module, CaddyManager),
      list_routes: Keyword.get(opts, :list_routes, &Applications.list_routes/0),
      notifier: Keyword.get(opts, :notifier),
      pending_ref: nil
    }

    Events.subscribe("fleet:changes")

    # First reconcile runs after the supervision tree is up so Caddy
    # has already been bootstrapped by the installer. Use a deferred
    # message so init/1 doesn't block on a round trip.
    send(self(), :initial_reconcile)

    {:ok, state}
  end

  @impl true
  def handle_call(:reconcile_now, _from, state) when is_map(state) do
    {:reply, run_reconcile(state), %{state | pending_ref: nil}}
  end

  @impl true
  def handle_info(:initial_reconcile, state) when is_map(state) do
    _ = run_reconcile(state)
    {:noreply, state}
  end

  def handle_info(:fleet_changed, state) when is_map(state) do
    ref = make_ref()
    Process.send_after(self(), {:debounced_reconcile, ref}, state.debounce_ms)
    {:noreply, %{state | pending_ref: ref}}
  end

  def handle_info({:debounced_reconcile, ref}, %{pending_ref: ref} = state) do
    _ = run_reconcile(state)
    {:noreply, %{state | pending_ref: nil}}
  end

  # A newer event raced ahead of this timer — a later debounced
  # reconcile is already scheduled. Drop this one.
  def handle_info({:debounced_reconcile, _stale_ref}, state) when is_map(state) do
    {:noreply, state}
  end

  # Ignore unrelated PubSub traffic that might show up on shared topics.
  def handle_info(_other, state) when is_map(state) do
    {:noreply, state}
  end

  defp run_reconcile(state) do
    entries = state.list_routes.()
    desired_ingress_routes = Ingress.build_routes(entries)

    result =
      with {:ok, config} <- state.caddy_module.get_config(),
           new_config = merge_ingress_routes(config, desired_ingress_routes),
           :ok <- state.caddy_module.load_config(new_config) do
        :ok
      else
        {:error, reason} = error ->
          Logger.warning("IngressReconciler: Caddy reconcile failed: #{inspect(reason)}")
          error
      end

    if state.notifier, do: send(state.notifier, {:ingress_reconciled, result})
    result
  end

  # Given the current Caddy config and the desired list of ingress
  # routes, drop any stale `still_ingress_*` routes and append the new
  # ones. Preserves all non-ingress routes and unrelated fields on the
  # still server so system routes and any agent-local app routes stay
  # untouched.
  defp merge_ingress_routes(config, desired) when is_map(config) and is_list(desired) do
    current_routes =
      config
      |> get_in(["apps", "http", "servers", "still", "routes"])
      |> List.wrap()

    preserved = Enum.reject(current_routes, &Ingress.ingress_route?/1)
    new_routes = CaddyBootstrap.with_catchall_last(preserved ++ desired)

    config
    |> ensure_servers_path()
    |> update_in(["apps", "http", "servers", "still"], fn existing ->
      Map.put(existing || %{}, "routes", new_routes)
    end)
  end

  defp ensure_servers_path(config) do
    config
    |> Map.put_new("apps", %{})
    |> update_in(["apps"], &Map.put_new(&1, "http", %{}))
    |> update_in(["apps", "http"], &Map.put_new(&1, "servers", %{}))
  end
end
