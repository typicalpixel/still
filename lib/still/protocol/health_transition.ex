defmodule Still.Protocol.HealthTransition do
  @moduledoc "Agent → Controller: health state change for an application."
  @enforce_keys [:server_id, :application, :from, :to, :timestamp]
  defstruct [:server_id, :application, :from, :to, :timestamp]
end
