defmodule SddOrchestratorWeb.Router do
  use SddOrchestratorWeb, :router

  import SddOrchestratorWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SddOrchestratorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_account
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Requires a valid application session for full-page controller routes.
  pipeline :require_account do
    plug :require_authenticated
  end

  scope "/", SddOrchestratorWeb do
    pipe_through :browser

    # GitHub authorization endpoints (full-page redirect flow).
    get "/auth/github", AuthController, :request
    get "/auth/github/callback", AuthController, :callback
    delete "/auth/sign_out", AuthController, :sign_out

    # Unauthenticated entry chooser; a valid session is sent to the catalog.
    live_session :redirect_if_authenticated,
      on_mount: [{SddOrchestratorWeb.UserAuth, :redirect_if_authenticated}] do
      live "/", EntryLive
    end

    # Public handoff for the local onboarding action (owned by specs/02).
    live_session :public, on_mount: [{SddOrchestratorWeb.UserAuth, :mount_current_account}] do
      live "/onboarding/local", LocalOnboardingLive
    end

    # Protected surfaces require a valid application session.
    live_session :authenticated,
      on_mount: [{SddOrchestratorWeb.UserAuth, :require_authenticated}] do
      live "/projects", ProjectsLive
      live "/onboarding/repository-access/:attempt_id", RepositoryAccessLive
      live "/onboarding/storage/:attempt_id", StorageSelectionLive
      live "/onboarding/device-setup/:attempt_id", DeviceSetupLive
      live "/onboarding/confirm/:attempt_id", ProjectConfirmationLive
    end
  end

  # GitHub App installation handoff and validated return (full-page redirects,
  # not LiveView). Both require an authenticated session.
  scope "/", SddOrchestratorWeb do
    pipe_through [:browser, :require_account]

    get "/github/install", GitHubSetupController, :install
    get "/github/setup", GitHubSetupController, :setup
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
    end
  end
end
