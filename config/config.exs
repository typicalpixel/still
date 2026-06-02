# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :still,
  ecto_repos: [Still.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true],
  auto_port_range: 20_000..29_999//2,
  applications_dir: "/var/lib/still/applications",
  artifacts_dir: "/var/lib/still/artifacts",
  artifact_base_url: "http://localhost:9090",
  artifact_retention: 10,
  caddy_admin_url: "http://localhost:2019",
  caddy_req_options: [],
  health_req_options: [retry: false],
  artifact_req_options: []

config :still, Still.Repo, migration_timestamps: [type: :utc_datetime_usec]

# Configure the endpoint
config :still, StillWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: StillWeb.ErrorHTML, json: StillWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Still.PubSub,
  live_view: [signing_salt: "kPq3vJ8x"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  still: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  still: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Throttle unauthenticated logins per client IP (brute-force defense). Enabled
# by default; the test and dev envs turn it off so it doesn't trip local flows.
config :still, :login_rate_limit, enabled: true, max_attempts: 10, window_ms: 60_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
