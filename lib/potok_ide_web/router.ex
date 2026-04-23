defmodule PotokIdeWeb.Router do
  use PotokIdeWeb, :router

  import PotokIdeWeb.AccountAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PotokIdeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PotokIdeWeb.Locale, :put_locale
    plug :fetch_current_scope_for_account
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser_json do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PotokIdeWeb.Locale, :put_locale
    plug :fetch_current_scope_for_account
  end

  scope "/.well-known", PotokIdeWeb do
    pipe_through :api

    get "/assetlinks.json", AssetLinksController, :show
    get "/apple-app-site-association", AppleAppSiteAssociationController, :show
  end

  scope "/", PotokIdeWeb do
    pipe_through :api

    get "/apple-app-site-association", AppleAppSiteAssociationController, :show
  end

  scope "/", PotokIdeWeb do
    pipe_through :browser

    get "/locale/:locale", LocaleController, :update
    get "/", PageController, :home
    get "/avatar/profile/:id", AvatarController, :profile
  end

  # Other scopes may use custom stacks.
  # scope "/api", PotokIdeWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:potok_ide, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PotokIdeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", PotokIdeWeb do
    pipe_through [:browser_json, :require_authenticated_account]

    post "/accounts/push-subscriptions", PushSubscriptionController, :create
    delete "/accounts/push-subscriptions", PushSubscriptionController, :delete
    post "/accounts/push-subscriptions/test", PushSubscriptionController, :test
  end

  scope "/", PotokIdeWeb do
    pipe_through [:browser, :require_authenticated_account]

    live_session :authenticated,
      on_mount: [
        {PotokIdeWeb.Locale, :mount_locale},
        {PotokIdeWeb.AccountAuth, :require_authenticated},
        {PotokIdeWeb.ProfileAuth, :mount_current_profile}
      ] do
      live "/profiles", ProfileLive.Index, :index
      live "/profiles/new", ProfileLive.New, :new
      live "/profiles/:id/edit", ProfileLive.Edit, :edit
    end

    live_session :profile_required,
      on_mount: [
        {PotokIdeWeb.Locale, :mount_locale},
        {PotokIdeWeb.AccountAuth, :require_authenticated},
        {PotokIdeWeb.ProfileAuth, :mount_current_profile},
        {PotokIdeWeb.ProfileAuth, :require_profile}
      ] do
      live "/profiles/:id/direct", ProfileLive.Direct, :show
      live "/groups", GroupLive.Root, :show
      live "/groups/:id/:tab", GroupLive.Show, :show
      live "/groups/:id", GroupLive.Show, :show
      live "/invitations", InvitationLive.Index, :index
      live "/requests", RequestLive.Index, :index
      live "/accounts/register", AccountLive.Registration, :new
      live "/accounts/settings", AccountLive.Settings, :edit
    end

    live_session :require_authenticated_account,
      on_mount: [
        {PotokIdeWeb.Locale, :mount_locale},
        {PotokIdeWeb.AccountAuth, :require_authenticated}
      ] do
      # live "/accounts/settings", AccountLive.Settings, :edit
      live "/accounts/settings/confirm-email/:token", AccountLive.Settings, :confirm_email
    end

    post "/accounts/update-password", AccountSessionController, :update_password
  end

  scope "/", PotokIdeWeb do
    pipe_through [:browser]

    live_session :current_account,
      on_mount: [
        {PotokIdeWeb.Locale, :mount_locale},
        {PotokIdeWeb.AccountAuth, :mount_current_scope}
      ] do
      live "/accounts/log-in", AccountLive.Login, :new
      live "/accounts/log-in/:token", AccountLive.Confirmation, :new
    end

    post "/accounts/log-in", AccountSessionController, :create
    delete "/accounts/log-out", AccountSessionController, :delete
  end
end
