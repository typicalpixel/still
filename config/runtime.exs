import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Runtime mode — single source of truth, derived from STILL_MODE env var.
# Tests default to :controller so agent GenServers don't start in the
# supervision tree (they're tested individually). Dev defaults to :standalone.
default_mode = if config_env() == :test, do: "controller", else: "standalone"

mode =
  case System.get_env("STILL_MODE", default_mode) do
    "controller" ->
      :controller

    "agent" ->
      :agent

    "standalone" ->
      :standalone

    other ->
      raise "Invalid STILL_MODE: #{inspect(other)}. Must be one of: controller, agent, standalone"
  end

config :still, :mode, mode

if mode == :agent do
  case System.get_env("STILL_CONTROLLER_NODE") do
    nil ->
      raise "STILL_CONTROLLER_NODE is required when STILL_MODE=agent"

    node ->
      config :still, :controller_node, String.to_atom(node)
  end
end

# `:server_id` identifies the local host to the controller's
# AgentConnectionManager. Agent, controller, and standalone all need it
# so the box can self-announce — without it, NodeConnector's announce
# is a no-op and the server row shows as `disconnected` even when it is
# literally this node. Dev sets a default in config/dev.exs; test skips
# the workers that read it; prod must provide one via the environment.
if config_env() == :prod do
  server_id =
    System.get_env("STILL_SERVER_ID") ||
      raise """
      environment variable STILL_SERVER_ID is missing.

      The install script generates a stable id into /etc/still/server.id
      and exports it via /etc/still/still.env.
      """

  config :still, :server_id, server_id
end

if System.get_env("PHX_SERVER") do
  config :still, StillWeb.Endpoint, server: true
end

config :still, StillWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if mode in [:controller, :standalone] and config_env() != :test do
  artifact_host = System.get_env("STILL_NODE_HOST", "127.0.0.1")
  artifact_port = System.get_env("STILL_INTERNAL_PORT", "9090")

  config :still,
         :artifact_base_url,
         System.get_env("STILL_ARTIFACT_BASE_URL") ||
           "http://#{artifact_host}:#{artifact_port}"
end

config :still,
       :ingress_edge_port,
       String.to_integer(System.get_env("STILL_INGRESS_EDGE_PORT", "8080"))

# erlexec (console PTYs) refuses to start under a root BEAM without an
# explicit opt-in. Still's agent runs as root, so opt in when we are root;
# euid via /proc/self ownership since the USER env var may be absent under
# systemd.
if match?({:ok, %{uid: 0}}, File.stat("/proc/self")) do
  config :erlexec, root: true, user: ~c"root", limit_users: [~c"root"]
end

if config_env() == :prod and mode != :agent do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/still/still.db
      """

  config :still, Still.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("STILL_CONTROLLER_DOMAIN") || "localhost"
  tls_mode = System.get_env("STILL_CONTROLLER_TLS", "off")

  config :still, :controller_domain, System.get_env("STILL_CONTROLLER_DOMAIN")

  url_config =
    case tls_mode do
      "auto" ->
        [host: host, port: 443, scheme: "https"]

      _ ->
        external_port = String.to_integer(System.get_env("STILL_CADDY_HTTP_PORT", "8080"))
        [host: host, port: external_port, scheme: "http"]
    end

  config :still, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Secure cookies come from the endpoint's Plug.RewriteOn, which reflects
  # Caddy's X-Forwarded-Proto into conn.scheme. We don't set `force_ssl` here —
  # Phoenix reads it at compile time, so a runtime value aborts boot on the
  # compile-env mismatch. See config/prod.exs.
  config :still, StillWeb.Endpoint,
    url: url_config,
    # Explicit instead of Phoenix's implicit `true`: lock the LiveView socket to
    # the controller domain when set, allow any origin otherwise. /live is gated
    # by a per-session CSRF token plus SameSite=Lax session cookies.
    # STILL_CHECK_ORIGIN overrides with a comma-separated allow-list.
    check_origin:
      StillWeb.OriginPolicy.check_origin(
        System.get_env("STILL_CONTROLLER_DOMAIN"),
        System.get_env("STILL_CHECK_ORIGIN")
      ),
    http: [
      # Phoenix is a backend only — Caddy host-scopes the controller route and
      # proxies it here over localhost. Binding to loopback keeps the
      # unencrypted API off the network so a misconfigured firewall can't
      # expose it.
      ip: {127, 0, 0, 1}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :still, StillWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :still, StillWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
