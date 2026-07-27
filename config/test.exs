import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :sdd_orchestrator, SddOrchestrator.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "sdd_orchestrator_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :sdd_orchestrator, SddOrchestratorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "0RsF1rYFR1sWZDLlCbUlRjb50f/EvCfhiXQsmytSMyRFgH9PiBys3KM9lG5o9x79",
  server: false

# Expose the non-product design-system preview at /_ui so the shared
# presentation-foundation LiveView and browser proofs can render it.
config :sdd_orchestrator, :ui_preview, true

# Field-encryption vault (fixed non-production test key).
config :sdd_orchestrator, SddOrchestrator.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("3YLEhIU/FRrY0Rkv8c0vhwsD/yqMSRtmfv+IUAURsmo=")}
  ]

# The retention pruner is driven directly in tests, not on a timer, so it never
# races the Ecto sandbox or deletes another test's data.
config :sdd_orchestrator, start_retention_pruner: false

# Exercise the local worker stand-in (pairing completion and folder selection) so
# the local-onboarding LiveView flow is driveable without the signed native worker.
config :sdd_orchestrator, :device_worker_stub, true

# Tests use the deterministic GitHub fake, never a live provider.
config :sdd_orchestrator, :github,
  provider: SddOrchestrator.GitHubIntegration.FakeProvider,
  app_origin: "http://localhost:4002",
  client_id: "test-client-id",
  client_secret: "test-client-secret"

config :sdd_orchestrator, SddOrchestrator.Mailer, adapter: Swoosh.Adapters.Test
config :sdd_orchestrator, :passwordless, app_origin: "http://localhost:4003"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
