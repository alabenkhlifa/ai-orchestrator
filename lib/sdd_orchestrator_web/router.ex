defmodule SddOrchestratorWeb.Router do
  use SddOrchestratorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SddOrchestratorWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SddOrchestratorWeb do
    pipe_through :browser

    get "/", PageController, :home
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
