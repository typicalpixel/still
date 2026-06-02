import Config

# TLS termination lives at the edge, not in Phoenix. Caddy terminates TLS and
# forwards X-Forwarded-Proto; the endpoint's Plug.RewriteOn reflects it into
# conn.scheme so cookies are marked secure, and Caddy's automatic_https owns the
# http→https redirect. Phoenix reads `force_ssl` at compile time, so it stays
# unset and the scheme is resolved per-request — adapting to STILL_CONTROLLER_TLS
# without a recompile.

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
