defmodule Still.Events do
  @moduledoc """
  Broadcasters for real-time events. Events are delivered over Phoenix PubSub
  for in-process consumers:

    * **Topic-specific PubSub broadcast** — e.g. `servers:lobby` for server
      connect/disconnect, `deployments:<name>` for per-app deploy progress,
      `health:<name>` for per-app health. LiveViews subscribe directly to the
      topics they need.

    * **Unified event stream** — every broadcast here also emits onto
      `events:source`, where `Still.EventLog` is the sole subscriber.
      The log retains each event in an ETS ring buffer (queryable via
      `GET /api/events`) and rebroadcasts on `events:lobby` for the
      dashboard's recent-activity feed.

  Public API clients poll the JSON endpoints for v0.1.0; there is no public
  WebSocket event contract.
  """

  @pubsub Still.PubSub
  @events_source "events:source"

  @doc """
  Broadcasts a server connection event on `servers:lobby` and logs it
  to the unified event stream.
  """
  def server_connected(server_id, node) when is_binary(server_id) and is_atom(node) do
    payload = %{server_id: server_id, node: node}
    broadcast("servers:lobby", {:server_connected, payload})
    emit(:server_connected, payload)
  end

  @doc """
  Broadcasts a server disconnection event on `servers:lobby` and emits
  it onto the unified event stream.
  """
  def server_disconnected(server_id) when is_binary(server_id) do
    payload = %{server_id: server_id}
    broadcast("servers:lobby", {:server_disconnected, payload})
    emit(:server_disconnected, payload)
  end

  @doc """
  Broadcasts a deployment progress event on `deployments:<application_name>`
  and emits it onto the unified event stream.
  """
  def deployment_updated(application_name, event)
      when is_binary(application_name) and is_map(event) do
    broadcast("deployments:#{application_name}", {:deployment_updated, event})
    emit(:deployment_updated, Map.put(event, :application_name, application_name))
  end

  @doc """
  Broadcasts a health transition event on `health:<application_name>`
  and emits it onto the unified event stream.
  """
  def health_transition(application_name, transition)
      when is_binary(application_name) and is_map(transition) do
    broadcast("health:#{application_name}", {:health_transition, transition})
    emit(:health_transition, Map.put(transition, :application_name, application_name))
  end

  @doc """
  Broadcasts a `:fleet_changed` event on `fleet:changes`. Fired after
  any mutation that could change the routing table: application
  create/update/delete, server assignment/unassignment, and fleet
  server create/update/delete. The `IngressReconciler` subscribes to
  this topic so the controller-side Caddy config stays current.
  """
  def fleet_changed do
    broadcast("fleet:changes", :fleet_changed)
  end

  @doc """
  Broadcasts a node-metrics sample on `servers:metrics`. Fired by
  `Still.MetricsCollector` each time an agent reports CPU/mem/disk
  utilization for a server.
  """
  def node_metrics(sample) when is_map(sample) do
    broadcast("servers:metrics", {:node_metrics, sample})
  end

  @doc """
  Broadcasts a deploy-log update on `deploy_logs:<deployment_id>`. Fired by
  `Still.DeployLogCollector` each time an agent reports captured journal for a
  step (and once more when the step's log is finalized). The deployment detail
  LiveView subscribes to re-read the live buffer.
  """
  def deploy_log_updated(deployment_id) when is_binary(deployment_id) do
    broadcast(
      "deploy_logs:#{deployment_id}",
      {:deploy_log_updated, %{deployment_id: deployment_id}}
    )
  end

  @doc """
  Broadcasts a per-application Caddy-metrics sample on
  `app_metrics:<application_name>`. Fired by `Still.CaddyMetricsScraper`
  after each scrape tick.
  """
  def app_metrics(application_name, sample)
      when is_binary(application_name) and is_map(sample) do
    broadcast("app_metrics:#{application_name}", {:app_metrics, sample})
  end

  @doc """
  Subscribes the calling process to the given topic.
  """
  def subscribe(topic) when is_binary(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  defp broadcast(topic, message) do
    Phoenix.PubSub.broadcast(@pubsub, topic, message)
  end

  # Publishes the event on the source topic that `Still.EventLog`
  # subscribes to. When the log isn't running (e.g. unit tests that
  # don't boot controller workers) the broadcast has no subscribers
  # and silently drops — broadcasters keep working.
  defp emit(type, payload) do
    event = %{type: type, payload: payload, at: DateTime.utc_now()}
    Phoenix.PubSub.broadcast(@pubsub, @events_source, {:event_recorded, event})
  end
end
