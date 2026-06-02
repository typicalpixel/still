defmodule StillWeb.EventJSON do
  @moduledoc """
  JSON serialization for the unified event stream. Each event carries a
  stable id, timestamp, type, and a type-specific payload map.
  """

  @doc "Renders a list of events for the index endpoint."
  def render(events) when is_list(events) do
    %{data: Enum.map(events, &event/1)}
  end

  @doc "Base shape for a single event."
  def event(%{id: id, type: type, payload: payload, at: %DateTime{} = at}) do
    %{
      id: id,
      type: type,
      payload: payload,
      at: at
    }
  end
end
