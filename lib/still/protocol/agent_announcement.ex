defmodule Still.Protocol.AgentAnnouncement do
  @moduledoc "Agent → Controller: sent on connect/reconnect with full runtime state."
  @enforce_keys [:server_id, :host, :state]
  defstruct [:server_id, :host, :state]
end
