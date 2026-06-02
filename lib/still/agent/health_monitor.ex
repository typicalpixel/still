defmodule Still.Agent.HealthMonitor do
  @moduledoc """
  Periodic health monitoring for the applications running on this agent.

  Each registered application is polled on its own schedule. Successful checks
  immediately mark the app `:healthy`. Failed checks accumulate against a
  configurable failure threshold; when the count exceeds it the app
  transitions to `:unhealthy`. Status transitions are sent to a configurable
  reporter function (in production this casts to the controller; in tests
  the reporter sends a message to the test process).

  The actual HTTP polling and the reporter function are both injectable
  (via `:health_req_options` config and the `:reporter` start option), so
  tests don't need to make real network calls or reach a real controller.
  """

  use GenServer

  require Logger

  @doc """
  Starts the HealthMonitor and registers it under the module name.

  Optional `:reporter` is a 1-arity function called with each status
  transition map. Defaults to a no-op.
  """
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Begins monitoring the given application. The first health check is queued
  immediately; subsequent checks fire every `:interval_ms` milliseconds.

  `config` is a map with keys: `:port`, `:path`, `:interval_ms`,
  `:timeout_ms`, `:failure_threshold`.
  """
  def register(application_name, config)
      when is_binary(application_name) and is_map(config) do
    GenServer.call(__MODULE__, {:register, application_name, config})
  end

  @doc """
  Stops monitoring the given application. Returns `:ok` whether or not the
  application was registered.
  """
  def unregister(application_name) when is_binary(application_name) do
    GenServer.call(__MODULE__, {:unregister, application_name})
  end

  @doc """
  Returns the current health status of an application.
  """
  def status(application_name) when is_binary(application_name) do
    GenServer.call(__MODULE__, {:status, application_name})
  end

  @doc """
  Lists the names of all currently monitored applications.
  """
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @impl true
  def init(opts) when is_list(opts) do
    reporter = Keyword.get(opts, :reporter, &default_reporter/1)
    {:ok, %{apps: %{}, reporter: reporter}}
  end

  @impl true
  def handle_call({:register, name, config}, _from, state) when is_map(state) do
    app = %{
      port: config.port,
      path: config.path,
      interval_ms: config.interval_ms,
      timeout_ms: config.timeout_ms,
      failure_threshold: config.failure_threshold,
      consecutive_failures: 0,
      status: :unknown,
      last_checked_at: nil
    }

    schedule_check(name, 0)
    {:reply, :ok, put_in(state.apps[name], app)}
  end

  def handle_call({:unregister, name}, _from, state) when is_map(state) do
    {:reply, :ok, %{state | apps: Map.delete(state.apps, name)}}
  end

  def handle_call({:status, name}, _from, state) when is_map(state) do
    case Map.fetch(state.apps, name) do
      {:ok, app} -> {:reply, {:ok, app.status}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) when is_map(state) do
    {:reply, Map.keys(state.apps), state}
  end

  @impl true
  def handle_info({:check, name}, state) when is_map(state) do
    case Map.fetch(state.apps, name) do
      {:ok, app} -> run_check_and_update(state, name, app)
      :error -> {:noreply, state}
    end
  end

  defp run_check_and_update(state, name, app) do
    result = perform_check(app)
    {new_app, transition?} = update_status(app, result)

    if transition? do
      state.reporter.(%{
        application: name,
        from: app.status,
        to: new_app.status,
        timestamp: DateTime.utc_now()
      })
    end

    schedule_check(name, app.interval_ms)
    {:noreply, put_in(state.apps[name], new_app)}
  end

  defp perform_check(app) when is_map(app) do
    url = "http://localhost:#{app.port}#{app.path}"

    case Req.get(req(), url: url, receive_timeout: app.timeout_ms) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      _ -> :error
    end
  end

  defp update_status(app, :ok) do
    new_app = %{
      app
      | status: :healthy,
        consecutive_failures: 0,
        last_checked_at: DateTime.utc_now()
    }

    {new_app, app.status != :healthy}
  end

  defp update_status(app, :error) do
    new_failures = app.consecutive_failures + 1

    new_status =
      if new_failures > app.failure_threshold do
        :unhealthy
      else
        app.status
      end

    new_app = %{
      app
      | status: new_status,
        consecutive_failures: new_failures,
        last_checked_at: DateTime.utc_now()
    }

    {new_app, app.status != new_status}
  end

  defp schedule_check(name, interval_ms) do
    Process.send_after(self(), {:check, name}, interval_ms)
  end

  defp req do
    Req.new(Application.get_env(:still, :health_req_options, []))
  end

  defp default_reporter(_transition), do: :ok
end
