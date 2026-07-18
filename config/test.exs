import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :still, Still.Repo,
  database: Path.expand("../still_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :still, StillWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Eou75r1KdiV1p4PjMdgB7mvcH07nQ//siWDEQOFUCiIRphgydYOsvvx1rtniHLuU",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Don't start controller workers (AgentConnectionManager, Orchestrator,
# ReconciliationLoop) automatically in test — tests that need them start
# them manually with custom options (stub agent callers, notifier pids).
config :still, start_controller_workers: false

# Login throttle off by default in test so unrelated login tests don't trip it;
# the rate-limit test enables it explicitly.
config :still, :login_rate_limit, enabled: false

# Setup Six
config :six,
  minimum_coverage: 100.0,
  track_ignores: true

# Route Caddy admin API HTTP through Req.Test stubs (no retries in tests)
config :still,
  caddy_req_options: [
    plug: {Req.Test, Still.Agent.CaddyManager},
    retry: false
  ]

# Route health-check HTTP through Req.Test stubs (no retries in tests)
config :still,
  health_req_options: [
    plug: {Req.Test, Still.Agent.HealthMonitor},
    retry: false
  ]

# Route artifact downloads through Req.Test stubs (no retries in tests)
config :still,
  artifact_req_options: [
    plug: {Req.Test, Still.Artifact.Provider.URL},
    retry: false
  ]

# Writable artifacts directory for tests that go through the Orchestrator's
# staging step. Each test module that needs isolation should override this
# via Application.put_env in its setup block.
config :still,
  artifacts_dir: Path.expand("../tmp/still_test_artifacts", __DIR__),
  artifact_base_url: "http://localhost:9090"

# Suite is clean on both checks; raise so regressions fail loudly.
config :phoenix_live_view, :test_warnings,
  duplicate_id: :raise,
  missing_form_id: :raise
