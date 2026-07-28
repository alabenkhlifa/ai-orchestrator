# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :sdd_orchestrator,
  ecto_repos: [SddOrchestrator.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :sdd_orchestrator, SddOrchestratorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SddOrchestratorWeb.ErrorHTML, json: SddOrchestratorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SddOrchestrator.PubSub,
  live_view: [signing_salt: "L5dd4bml"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  sdd_orchestrator: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  sdd_orchestrator: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Passwordless delivery stays adapter-backed. Development uses the local mailbox;
# tests override it with Swoosh's deterministic test adapter, and production
# provider selection remains an explicit Slice 03 release gate.
config :sdd_orchestrator, SddOrchestrator.Mailer, adapter: Swoosh.Adapters.Local

config :sdd_orchestrator,
       :magic_link_delivery,
       SddOrchestrator.HostedAccess.SwooshDelivery

config :sdd_orchestrator, :passwordless,
  app_origin: "http://localhost:4000",
  from_email: "no-reply@sdd-orchestrator.local",
  magic_link_ttl_seconds: 15 * 60,
  session_lifetime_seconds: 30 * 24 * 60 * 60,
  rate_limits: [
    email: [capacity: 5, window_ms: 15 * 60 * 1_000],
    ip: [capacity: 20, window_ms: 15 * 60 * 1_000],
    global: [capacity: 100, window_ms: 60 * 1_000]
  ]

config :sdd_orchestrator, :passwordless_retention,
  magic_link_attempt_grace_seconds: 24 * 60 * 60,
  hosted_session_grace_seconds: 24 * 60 * 60

config :swoosh, :api_client, false

# GitHub provider adapter and the registered public GitHub App identity.
# Secrets (client id/secret, private key) and the deployment origin are supplied
# per environment; only non-secret, stable defaults live here.
config :sdd_orchestrator, :github,
  provider: SddOrchestrator.GitHubIntegration.ReqProvider,
  app_slug: "orchestra-workflow",
  api_version: "2026-03-10",
  authorize_url: "https://github.com/login/oauth/authorize",
  token_url: "https://github.com/login/oauth/access_token",
  api_base_url: "https://api.github.com",
  # Onboarding relies on repository metadata only. No repository write
  # permission is approved for this slice; onboarding calls no write endpoint.
  approved_repository_permissions: %{"metadata" => "read"},
  # Identity linking reads only the verified-primary email attribute
  # (`user:email` / `read:user`). No repository write permission is requested.
  approved_email_permission: %{"email" => "read"}

# Accountless on-device data is served through a DeviceStore adapter and never
# stored in the hosted database. Development and tests use the local adapter; the
# native macOS worker adapter is a Slice 02 release gate.
config :sdd_orchestrator, SddOrchestrator.Devices,
  adapter: SddOrchestrator.Devices.DeviceStore.Local

# The native macOS worker (release-gated) completes pairing over its outbound
# transport and opens the operating-system folder picker. Off (production) the
# local-onboarding UI waits on the real worker; dev and test enable a local
# stand-in so the graphical flow is exercisable without a signed binary.
config :sdd_orchestrator, :device_worker_stub, false

# Cloak vault ciphers are configured per environment because the key is a secret.

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
