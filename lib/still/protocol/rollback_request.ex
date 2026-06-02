defmodule Still.Protocol.RollbackRequest do
  @moduledoc "Controller → Agent: roll back to the previous version."
  @enforce_keys [:application]
  defstruct [:application]
end
