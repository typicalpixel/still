defmodule Still.EventFixtures do
  @moduledoc """
  Builds event maps for seeding `Still.EventLog` or exercising the
  unified event-stream shape. Defaults describe a bare
  `:server_connected` event; override `:type`, `:payload`, or `:at`.
  """

  @doc """
  Builds an event map with sensible defaults. Attrs can be a map or
  keyword list and override any field.
  """
  def event_fixture(attrs) when is_map(attrs) or is_list(attrs) do
    defaults = %{
      type: :server_connected,
      payload: %{server_id: "srv-#{System.unique_integer([:positive])}"},
      at: DateTime.utc_now()
    }

    Map.merge(defaults, Map.new(attrs))
  end
end
