defmodule Still.AgentFixtures do
  @moduledoc """
  Shared builders for the in-memory maps agents push to the controller
  (`AgentConnectionManager.agent_connected/1` payloads and the per-app
  entries that ride inside them).

  The controller stores these verbatim in ETS and surfaces them through
  `/api/status/*` — keep the default shape in sync with
  `Still.Agent.NodeConnector.build_report/1` so tests that mimic a live
  agent exercise the real field set.
  """

  @doc """
  Builds an agent-report map with sensible defaults. Attrs override
  individual fields — the common case is overriding `:server_id` and
  optionally `:applications` or `:system_info`. Pass `%{}` for a pure
  defaults payload.
  """
  def agent_report_fixture(attrs) when is_map(attrs) or is_list(attrs) do
    defaults = %{
      server_id: Ecto.UUID.generate(),
      node: :"still_agent@127.0.0.1",
      connected_at: DateTime.utc_now(),
      applications: []
    }

    Map.merge(defaults, Map.new(attrs))
  end

  @doc """
  Builds one of the per-application entries inside a report's
  `:applications` list. Defaults describe a healthy blue slot running
  an arbitrary version; override `:application_name` when the caller
  cares about identity.
  """
  def reported_application_fixture(attrs) when is_map(attrs) or is_list(attrs) do
    defaults = %{
      application_name: "app-#{System.unique_integer([:positive])}",
      type: "elixir_release",
      active_slot: :blue,
      active_port: 20_000,
      current_version: "1.0.0",
      previous_version: nil,
      health: :healthy,
      last_health_check_at: DateTime.utc_now(),
      pid: 4321,
      active_state: "active",
      active_enter_at: DateTime.utc_now()
    }

    Map.merge(defaults, Map.new(attrs))
  end
end
