import Config

# Set by `rel/overlays/worker/env.sh.eex` before the `:worker` release's
# `bin/worker start` boots the VM (see `mix.exs`'s `releases/0` and
# `SddOrchestrator.Application`). A genuinely remote worker has no
# database, vault, endpoint, or GitHub OAuth app, so the control-plane
# secret checks below must not run for it.
worker_release_mode? = System.get_env("SDD_ORCHESTRATOR_RELEASE_MODE") == "worker"

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/sdd_orchestrator start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :sdd_orchestrator, SddOrchestratorWeb.Endpoint, server: true
end

config :sdd_orchestrator, SddOrchestratorWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  if device_store_path = System.get_env("E2E_DEVICE_STORE_PATH") do
    config :sdd_orchestrator, SddOrchestrator.Devices.DeviceStore.Local,
      start: true,
      path: device_store_path
  end
end

# A public deployment may select either a compiled delivery boundary or a
# compiled Swoosh adapter without placing provider credentials in source.
# Task 7's release gate still requires the matching processor, region, transfer,
# retention, and review evidence before that deployment is considered ready.
if delivery_module = System.get_env("PASSWORDLESS_DELIVERY_MODULE") do
  config :sdd_orchestrator,
         :magic_link_delivery,
         Module.safe_concat(String.split(delivery_module, "."))
end

if mailer_adapter = System.get_env("PASSWORDLESS_MAILER_ADAPTER") do
  config :sdd_orchestrator,
         SddOrchestrator.Mailer,
         adapter: Module.safe_concat(String.split(mailer_adapter, "."))
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :sdd_orchestrator, SddOrchestratorWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/sdd_orchestrator_web/router\.ex$"E,
        ~r"lib/sdd_orchestrator_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod and not worker_release_mode? do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :sdd_orchestrator, SddOrchestrator.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

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

  host = System.get_env("PHX_HOST") || "example.com"

  config :sdd_orchestrator, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :sdd_orchestrator, SddOrchestratorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # Field-encryption key (base64 of 32 bytes) for the Cloak vault. Required so
  # provider credentials and PKCE verifiers are encrypted at rest.
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      Generate one with: mix phx.gen.secret 32 | base64  (32 raw bytes, base64-encoded)
      """

  config :sdd_orchestrator, SddOrchestrator.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key)}
    ]

  # Registered public GitHub App credentials and the deployment origin. The
  # callback and setup URLs are derived from APP_ORIGIN by the application. The
  # app id and PEM private key sign short-lived app JWTs for the pending
  # installation-request lookup; they are optional so the app still boots without
  # the app-level read configured.
  config :sdd_orchestrator, :github,
    app_origin: System.fetch_env!("APP_ORIGIN"),
    client_id: System.fetch_env!("GITHUB_CLIENT_ID"),
    client_secret: System.fetch_env!("GITHUB_CLIENT_SECRET"),
    app_id: System.get_env("GITHUB_APP_ID"),
    app_private_key: System.get_env("GITHUB_APP_PRIVATE_KEY")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :sdd_orchestrator, SddOrchestratorWeb.Endpoint,
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
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :sdd_orchestrator, SddOrchestratorWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
