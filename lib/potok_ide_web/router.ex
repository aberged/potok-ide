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

  # Public, cacheable image responses: no session, CSRF or account lookups.
  pipeline :avatars do
    plug :put_secure_browser_headers
  end

  # Files attached to values: the account's session decides access, and the
  # response is the file (or a redirect to it), never a page.
  pipeline :files do
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_account
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

  pipeline :require_unauthenticated_account do
    plug :redirect_if_account_is_authenticated
  end

  # Before `:require_authenticated_account`: a guest at the link of a public
  # group or event gets a preview of it instead of the redirect to log in.
  pipeline :public_preview do
    plug PotokIdeWeb.PublicPreview
  end

  # The installed web app's share target, posted by the browser: it only
  # passes the text on to `/share`, so it needs no session or CSRF token.
  pipeline :share_target do
    plug :put_secure_browser_headers
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
    get "/privacy-policy", PageController, :privacy
    get "/domain", PageController, :domain
    get "/stack", PageController, :stack
    get "/origin", PageController, :origin
  end

  # The service worker takes these posts (`priv/static/sw.js`); this is for
  # when no worker controls the page yet.
  scope "/", PotokIdeWeb do
    pipe_through :share_target

    post "/share-target", ShareTargetController, :create
  end

  scope "/avatar", PotokIdeWeb do
    pipe_through :avatars

    get "/profile/:id", AvatarController, :profile
    get "/group/:id", AvatarController, :group
  end

  # Map tiles from OpenStreetMap, kept on disk (`PotokIde.MapTiles`): the maps
  # in apps and in a group's settings, with no session, as with avatars.
  scope "/tiles", PotokIdeWeb do
    pipe_through :avatars

    get "/:z/:x/:y", MapTileController, :show
  end

  # What sites and apps fetch for the card of a shared link (`13.jpg`): only for
  # what guests can see, and with no session, as with avatars.
  scope "/cards", PotokIdeWeb do
    pipe_through :avatars

    get "/group/:file", CardController, :group
    get "/event/:file", CardController, :event
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

  # A picture in a description, by its signed address: non-members and an app's
  # sandboxed frame see descriptions too, and have no session to show here.
  scope "/pictures", PotokIdeWeb do
    pipe_through :avatars

    get "/:token", AttachmentController, :picture
  end

  # A file an app shows in its sandboxed frame, which sends no session, by an
  # address that lives ten minutes (`PotokIdeWeb.AppFileToken`).
  scope "/app_files", PotokIdeWeb do
    pipe_through :avatars

    get "/:token", AttachmentController, :app_file
  end

  # Logged-out visitors go to the login page and come back here afterwards;
  # the controller then checks that they read the chat the file was posted in.
  scope "/files", PotokIdeWeb do
    pipe_through [:files, :require_authenticated_account]

    get "/:id", AttachmentController, :show
  end

  # A calendar file of an event, like `/files`: logged-out visitors log in
  # and come back, and the controller checks membership in the event's group.
  scope "/events", PotokIdeWeb do
    pipe_through [:files, :require_authenticated_account]

    get "/:id/event.ics", EventIcsController, :show
  end

  # The results of a poll as a file, like `/files`: logged-out visitors log in
  # and come back, and the controller asks the poll's rules for this profile.
  scope "/polls", PotokIdeWeb do
    pipe_through [:files, :require_authenticated_account]

    get "/:id/results.csv", PollExportController, :show
  end

  scope "/", PotokIdeWeb do
    pipe_through [:browser, :public_preview, :require_authenticated_account]

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
      live "/share", ShareLive, :index
      live "/groups/:id/:tab", GroupLive.Show, :show
      live "/groups/:id", GroupLive.Show, :show
      live "/invitations", InvitationLive.Index, :index
      live "/requests", RequestLive.Index, :index
      live "/tags", TagLive.Index, :index
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
    pipe_through [:browser, :require_unauthenticated_account]

    live_session :current_account,
      on_mount: [
        {PotokIdeWeb.Locale, :mount_locale},
        {PotokIdeWeb.AccountAuth, :redirect_if_authenticated}
      ] do
      live "/accounts/log-in", AccountLive.PasswordLogin, :new
      live "/accounts/log-in/password", AccountLive.PasswordLogin, :new
      live "/accounts/log-in/magic-link", AccountLive.Login, :new
      live "/accounts/log-in/:token", AccountLive.Confirmation, :new
    end

    post "/accounts/log-in", AccountSessionController, :create
    # A plain POST rather than a LiveView event: the rate limit needs the IP.
    post "/accounts/log-in/magic-link", AccountSessionController, :magic_link
  end

  scope "/", PotokIdeWeb do
    pipe_through [:browser]

    delete "/accounts/log-out", AccountSessionController, :delete
  end
end
