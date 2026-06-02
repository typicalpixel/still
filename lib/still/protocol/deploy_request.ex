defmodule Still.Protocol.DeployRequest do
  @moduledoc "Controller → Agent: trigger a deploy on this server."

  @enforce_keys [
    :application,
    :type,
    :version,
    :artifact_url,
    :domain,
    :env_vars,
    :health_check,
    :hooks,
    :port_blue,
    :port_green
  ]

  defstruct [
    :application,
    :type,
    :version,
    :artifact_url,
    :domain,
    :path_prefix,
    :env_vars,
    :exec_command,
    :exec_start_pre,
    :exec_stop,
    :user,
    :drain_ms,
    :stop_timeout_ms,
    :health_check,
    :hooks,
    :port_blue,
    :port_green
  ]
end
