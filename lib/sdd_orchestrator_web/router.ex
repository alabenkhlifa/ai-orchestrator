defmodule SddOrchestratorWeb.Router do
  use SddOrchestratorWeb, :router

  import SddOrchestratorWeb.UserAuth
  import SddOrchestratorWeb.HostedUserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SddOrchestratorWeb.Layouts, :root}
    plug :protect_from_forgery
    # A static baseline Content-Security-Policy is set here; the plug below replaces
    # it with the full per-request nonce policy (the nonce cannot be a compile-time
    # plug option).
    plug :put_secure_browser_headers, %{"content-security-policy" => "default-src 'self'"}
    plug :put_content_security_policy
    plug :fetch_current_account
    plug :fetch_current_hosted_access
  end

  # A strict Content-Security-Policy with a per-request nonce for the device-local
  # pre-paint theme script (the only inline script). Everything else is same-origin:
  # no external scripts, styles, fonts, images, or connections, so an accidental
  # third-party asset or injected inline script is blocked. The nonce is exposed as
  # `@csp_nonce` for the root layout.
  defp put_content_security_policy(conn, _opts) do
    nonce = Base.encode64(:crypto.strong_rand_bytes(18))

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", content_security_policy(nonce))
  end

  defp content_security_policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "base-uri 'self'",
        "frame-ancestors 'none'",
        "object-src 'none'",
        "img-src 'self' data:",
        "font-src 'self'",
        "style-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "connect-src 'self'",
        "form-action 'self'"
      ],
      "; "
    )
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Requires a valid application session for full-page controller routes.
  pipeline :require_account do
    plug :require_authenticated
  end

  # Hosted session-management actions never accept the GitHub application
  # session as a substitute for a verified hosted identity.
  pipeline :require_hosted do
    plug :require_hosted_authenticated
  end

  scope "/", SddOrchestratorWeb do
    pipe_through :browser

    # GitHub authorization endpoints (full-page redirect flow).
    get "/auth/github", AuthController, :request
    get "/auth/github/callback", AuthController, :callback
    delete "/auth/sign_out", AuthController, :sign_out

    # Delivered passwordless credentials return through one account-neutral
    # verification endpoint before any hosted surface is exposed.
    get "/hosted/access/verify", HostedAccessController, :verify
    delete "/hosted/session", HostedSessionController, :delete_current

    # Passwordless proof link for identity linking; account-neutral, no session
    # required so the proof is recorded even if opened outside the GitHub session.
    get "/identity/link/verify", IdentityLinkController, :verify

    # Unauthenticated entry chooser; a valid session is sent to the catalog.
    live_session :redirect_if_authenticated,
      on_mount: [{SddOrchestratorWeb.UserAuth, :redirect_if_authenticated}] do
      live "/", EntryLive
    end

    # Accountless local onboarding and its on-device project dashboard (specs/02).
    live_session :public, on_mount: [{SddOrchestratorWeb.UserAuth, :mount_current_account}] do
      live "/onboarding/local", LocalOnboardingLive
      live "/local/projects/:id", DeviceProjectDashboardLive
    end

    live_session :hosted_access_public,
      on_mount: [{SddOrchestratorWeb.HostedUserAuth, :mount_current_hosted_access}] do
      live "/hosted/access", HostedAccessLive
      live "/hosted/access/result", HostedAccessResultLive
    end

    # Protected surfaces require a valid application session.
    live_session :authenticated,
      on_mount: [{SddOrchestratorWeb.UserAuth, :require_authenticated}] do
      live "/projects", ProjectsLive
      live "/projects/:id", ProjectDashboardLive
      live "/onboarding/repository-access/:attempt_id", RepositoryAccessLive
      live "/onboarding/storage/:attempt_id", StorageSelectionLive
      live "/onboarding/device-setup/:attempt_id", DeviceSetupLive
      live "/onboarding/confirm/:attempt_id", ProjectConfirmationLive

      # GitHub-to-passwordless identity-linking confirmation flow.
      live "/identity/link/:id", IdentityLinkLive
    end
  end

  # GitHub App installation handoff and validated return (full-page redirects,
  # not LiveView). Both require an authenticated session.
  scope "/", SddOrchestratorWeb do
    pipe_through [:browser, :require_account]

    get "/github/install", GitHubSetupController, :install
    get "/github/setup", GitHubSetupController, :setup
  end

  scope "/", SddOrchestratorWeb do
    pipe_through [:browser, :require_hosted]

    live_session :hosted_access_authenticated,
      on_mount: [{SddOrchestratorWeb.HostedUserAuth, :require_hosted_authenticated}] do
      live "/hosted/access/sessions", HostedSessionsLive
    end

    delete "/hosted/sessions/:id", HostedSessionController, :delete
    delete "/hosted/sessions", HostedSessionController, :delete_all
  end

  # Non-product design-system preview. Available only in dev and test as the
  # render surface for the shared presentation-foundation proofs.
  if Application.compile_env(:sdd_orchestrator, :ui_preview, false) do
    scope "/", SddOrchestratorWeb do
      pipe_through :browser

      live "/_ui", UIPreviewLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", SddOrchestratorWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:sdd_orchestrator, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SddOrchestratorWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
