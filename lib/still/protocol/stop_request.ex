defmodule Still.Protocol.StopRequest do
  @moduledoc "Controller → Agent: stop the application on this server."
  @enforce_keys [:application]
  defstruct [:application]
end
