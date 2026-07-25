defmodule Still.Caddy.Tracing do
  @moduledoc """
  Opt-in OpenTelemetry spans on the Caddy routes Still writes.

  Off by default. Set `config :still, caddy_tracing: true`
  (`STILL_CADDY_TRACING=1`) on each node whose Caddy should trace, and point
  that Caddy process at an OTLP collector with the standard `OTEL_*`
  environment variables. With it off, the route JSON Still emits is
  unchanged.

  Only per-application routes are traced — the agent-local route and the
  controller's ingress route — each with a span named after the application.
  Still's own dashboard and API route, the system catch-all, and the internal
  artifacts server are never traced, so operating Still doesn't show up in
  your applications' traces.
  """

  alias Still.Caddy.Config, as: CaddyConfig

  @doc "Whether route writers should emit the `tracing` handler."
  def enabled?, do: Application.get_env(:still, :caddy_tracing, false) == true

  @doc """
  Prepends a `tracing` handler named `span` to `handle` so the span covers
  everything the route does. Returns `handle` unchanged when tracing is
  disabled.
  """
  def prepend(handle, span) when is_list(handle) do
    if enabled?() do
      [CaddyConfig.tracing(span: span) | handle]
    else
      handle
    end
  end
end
