defmodule Still.RecordingServer do
  @moduledoc """
  A loopback HTTP server that records every request it receives and answers
  `200`. Integration tests use it for both ends of a traced request: as the
  OTLP collector Caddy exports spans to, and as the upstream Caddy proxies
  to when asserting what headers were forwarded.

  Request bodies are kept as raw bytes rather than decoded. A span name
  travels the OTLP protobuf wire as a plain UTF-8 string field, so matching
  bytes is enough to prove a named span was exported without pulling in a
  protobuf dependency.
  """

  @behaviour Plug

  import Plug.Conn

  # Runs only under `--include integration`, which the default coverage run
  # excludes.
  # six:ignore:start

  @doc "Starts a server on a free loopback port."
  def start! do
    port = Still.IntegrationCase.free_port()
    {:ok, agent} = Agent.start(fn -> [] end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__, agent},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port,
        startup_log: false
      )

    %{port: port, endpoint: "http://127.0.0.1:#{port}", agent: agent, server: server}
  end

  @doc "Stops a server started with `start!/0`. Idempotent."
  def stop!(%{agent: agent, server: server}) do
    if Process.alive?(server), do: stop_quietly(server)
    if Process.alive?(agent), do: stop_quietly(agent)
    :ok
  end

  # Bandit's listener supervisor terminates with `:shutdown`, which
  # Supervisor.stop/1 re-raises as an exit in the calling test process.
  defp stop_quietly(pid) do
    Supervisor.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Requests received so far, newest first, as
  `%{path: path, headers: headers, body: body}`.
  """
  def requests(%{agent: agent}), do: Agent.get(agent, & &1)

  @doc """
  Whether an OTLP export carrying a span named `span` has arrived. Matches
  the raw protobuf payload posted to `/v1/traces`.
  """
  def exported_span?(collector, span) when is_binary(span) do
    Enum.any?(requests(collector), fn request ->
      request.path == "/v1/traces" and String.contains?(request.body, span)
    end)
  end

  @doc """
  Blocks until a span named `span` has been exported, raising after
  `timeout_ms`. Caddy batches spans, so the collector lags the response that
  produced them.
  """
  def await_span!(collector, span, timeout_ms \\ 15_000) do
    Still.IntegrationCase.wait_until!(fn -> exported_span?(collector, span) end, timeout_ms)
  end

  @doc "The first value of `name` across recorded requests, or nil."
  def recorded_header(server, name) when is_binary(name) do
    server
    |> requests()
    |> Enum.reverse()
    |> Enum.find_value(fn request ->
      Enum.find_value(request.headers, fn
        {^name, value} -> value
        _ -> nil
      end)
    end)
  end

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(conn, agent) do
    {:ok, body, conn} = read_body(conn, length: 10_000_000)

    request = %{path: conn.request_path, headers: conn.req_headers, body: body}
    Agent.update(agent, &[request | &1])

    conn
    |> put_resp_content_type("application/x-protobuf")
    |> send_resp(200, "")
  end

  # six:ignore:stop
end
