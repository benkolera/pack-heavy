defmodule PackheavyWeb.Router do
  use PackheavyWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PackheavyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  # ALB target group health check — outside :browser, no auth, no session.
  scope "/", PackheavyWeb do
    get "/health", HealthController, :index
  end

  # Public read-only trip share. Goes through :browser so LV works,
  # but is OUTSIDE the ash_authentication_live_session so anonymous
  # users can hit it. Authorization is enforced by the
  # :read_by_share_token action's policy bypass + filter on the Trip
  # resource — see lib/packheavy/trips/trip.ex.
  scope "/share", PackheavyWeb do
    pipe_through :browser
    live "/trip/:token", PublicTripLive, :show
  end

  scope "/", PackheavyWeb do
    pipe_through :browser

    ash_authentication_live_session :authenticated_routes,
      on_mount: {PackheavyWeb.LiveUserAuth, :live_user_required} do
      live "/dashboard", DashboardLive, :index
      live "/items", ItemLive.Index, :index
      live "/items/new", ItemLive.Index, :new
      live "/items/:id/edit", ItemLive.Index, :edit
      live "/cable-types", CableTypeLive.Index, :index
      live "/battery-types", BatteryTypeLive.Index, :index
      live "/kits", KitLive.Index, :index
      live "/kits/new", KitLive.Index, :new
      live "/kits/:id", KitLive.Show, :show
      live "/trips", TripLive.Index, :index
      live "/trips/new", TripLive.Index, :new
      live "/trips/:id", TripLive.Show, :show
      live "/backup", BackupLive, :index
    end

    # Backup export needs the regular controller pipeline (not LV) so
    # the browser can stream the file as a download.
    get "/backup/export", BackupController, :export
  end

  scope "/", PackheavyWeb do
    pipe_through :browser

    get "/", PageController, :home
    auth_routes AuthController, Packheavy.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # Single-user app: no self-signup. `register_path` omitted so /register
    # is not generated. Seed the lone user via priv/scripts/create_user.exs
    # against the prod RDS endpoint (see infra/README.md).
    sign_in_route auth_routes_prefix: "/auth",
                  on_mount: [{PackheavyWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    PackheavyWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.DaisyUI
                  ]

  end

  # Other scopes may use custom stacks.
  # scope "/api", PackheavyWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:packheavy, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PackheavyWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
