# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :potok_ide, :scopes,
  account: [
    default: true,
    module: PotokIde.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:account, :id],
    schema_key: :account_id,
    schema_type: :id,
    schema_table: :accounts,
    test_data_fixture: PotokIde.AccountsFixtures,
    test_setup_helper: :register_and_log_in_account
  ]

config :potok_ide,
  ecto_repos: [PotokIde.Repo],
  generators: [timestamp_type: :utc_datetime]

config :potok_ide, :android_app_links, package_name: "rs.potok.ide"

# In dev/test, Plug.SSL canonical redirect is disabled (no canonical host).
config :potok_ide, :canonical_host, nil

# How long a group LiveView collects `group_updated` / unread broadcasts
# before reloading once (see GroupLive.Show.schedule_refresh/2).
config :potok_ide, live_refresh_debounce_ms: 100

config :potok_ide, :ios_app_links,
  bundle_id: "rs.potok.ide",
  paths: ["/accounts/log-in/*"]

# Configure the endpoint
config :potok_ide, PotokIdeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PotokIdeWeb.ErrorHTML, json: PotokIdeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PotokIde.PubSub,
  live_view: [signing_salt: "0toMDt7c"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :potok_ide, PotokIde.Mailer,
  adapter: Swoosh.Adapters.Local,
  from_name: "Potok",
  from_email: "no-reply@example.com"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  potok_ide: [
    args:
      ~w(js/app.js --bundle --target=es2022 --format=esm --splitting --chunk-names=chunks/[name]-[hash] --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # Classic (non-module) script loaded inside sandboxed app iframes.
  potok_app_sdk: [
    args:
      ~w(js/potok_app_sdk.js --bundle --target=es2020 --format=iife --outfile=../priv/static/assets/js/potok_app_sdk.js),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  potok_ide: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :potok_ide, PotokIde.PushNotifications, ttl: 60

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
