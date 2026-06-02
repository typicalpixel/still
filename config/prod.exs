import Config

# TLS termination lives at the edge, not in Phoenix. runtime.exs turns on
# force_ssl only under STILL_CONTROLLER_TLS=auto, where Caddy terminates TLS
# and forwards X-Forwarded-Proto — enough for Plug.SSL to mark cookies secure
# and emit HSTS. Caddy's automatic_https owns the http→https redirect, so
# Phoenix never issues one of its own. Under :off the edge serves plain HTTP
# and force_ssl stays off.

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
