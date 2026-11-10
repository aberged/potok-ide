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

# PostGIS geometries (a group's area on a map) come and go as `Geo` structs.
config :potok_ide, PotokIde.Repo, types: PotokIde.PostgresTypes
config :geo_postgis, json_library: Jason

config :potok_ide, :android_app_links, package_name: "rs.potok.ide"

# In dev/test, Plug.SSL canonical redirect is disabled (no canonical host).
config :potok_ide, :canonical_host, nil

# How long a group LiveView collects `group_updated` / unread broadcasts
# before reloading once (see GroupLive.Show.schedule_refresh/2).
config :potok_ide, live_refresh_debounce_ms: 100

# How long after a page mounts its websocket and LiveView processes collect
# the garbage that rendering the page left (see ProfileAuth); nil turns it off.
config :potok_ide, transport_gc_delay_ms: 2_000

# After that, how often a page looks at its websocket process and has it
# collect once its heap has grown past the threshold, in words (see
# ProfileAuth). Every update a page sends leaves its encoded frame there as
# garbage: ~110 KB per connection in the load test, ~8 KB once collected.
config :potok_ide, transport_gc_interval_ms: 20_000, transport_gc_threshold_words: 4_096

# Files attached to values (see PotokIde.Storage). Without an adapter
# attachments are off; dev and test keep files on disk, and runtime.exs
# switches to a bucket when BUCKET_NAME is set.
config :potok_ide, PotokIde.Storage,
  adapter: nil,
  max_files: 10,
  max_file_size: 100_000_000

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
  # A page hibernates (its heap shrinks to its live data) after 2 s with no
  # message, not LiveView's 15 s: with updates every few seconds a page was
  # never idle that long, and kept ~166 KB where ~63 KB was live (load test,
  # 2026-11-09; CPU about the same).
  live_view: [signing_salt: "0toMDt7c", hibernate_after: 2_000]

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

# A vote's answers stay out of the logs, with what the default keeps out.
config :phoenix, :filter_parameters, ["password", "option_ids"]

config :potok_ide, PotokIde.PushNotifications, ttl: 60

# Event times are kept in the IANA zone of the event, so recurring events keep
# their wall-clock time across daylight saving changes.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# How often the scheduler looks for event reminders that are due.
config :potok_ide, PotokIde.Events.ReminderScheduler,
  enabled: true,
  interval_ms: 30_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
