defmodule Still.Protocol.DeployProgress do
  @moduledoc "Agent → Controller: per-step progress during a deploy."
  @enforce_keys [:server_id, :application, :version, :step, :timestamp]
  defstruct [:server_id, :application, :version, :step, :timestamp]
end
