import Config

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
#     PHX_SERVER=true bin/potok_ide start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :potok_ide, PotokIdeWeb.Endpoint, server: true
end

config :potok_ide, PotokIdeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

parse_env_list = fn
  nil ->
    nil

  value ->
    value
    |> String.split(~r/[\r\n,]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
end

android_app_links = Application.get_env(:potok_ide, :android_app_links, [])

android_app_links =
  android_app_links
  |> Keyword.put(
    :package_name,
    System.get_env("ANDROID_APP_LINK_PACKAGE") ||
      Keyword.get(android_app_links, :package_name, "com.potok.ide")
  )
  |> then(fn config ->
    case parse_env_list.(System.get_env("ANDROID_APP_LINK_SHA256_CERT_FINGERPRINTS")) do
      nil -> config
      fingerprints -> Keyword.put(config, :sha256_cert_fingerprints, fingerprints)
    end
  end)

config :potok_ide, :android_app_links, android_app_links

web_push_vapid_subject = System.get_env("WEB_PUSH_VAPID_SUBJECT")
web_push_vapid_public_key = System.get_env("WEB_PUSH_VAPID_PUBLIC_KEY")
web_push_vapid_private_key = System.get_env("WEB_PUSH_VAPID_PRIVATE_KEY")

if Enum.all?(
     [web_push_vapid_subject, web_push_vapid_public_key, web_push_vapid_private_key],
     &(is_binary(&1) and String.trim(&1) != "")
   ) do
  config :potok_ide, PotokIde.PushNotifications,
    vapid_subject: web_push_vapid_subject,
    vapid_public_key: web_push_vapid_public_key,
    vapid_private_key: web_push_vapid_private_key
end

if config_env() == :prod do
  present? = fn
    value when is_binary(value) -> String.trim(value) != ""
    _ -> false
  end

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :potok_ide, PotokIde.Repo,
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

  config :potok_ide, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :potok_ide, PotokIdeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :potok_ide, PotokIdeWeb.Endpoint,
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
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :potok_ide, PotokIdeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  mailer_from_email =
    System.get_env("MAILER_FROM_EMAIL") ||
      raise "environment variable MAILER_FROM_EMAIL is missing"

  mailer_from_name = System.get_env("MAILER_FROM_NAME") || "Potok"

  mailer_adapter =
    System.get_env("MAILER_ADAPTER")
    |> case do
      nil -> "mailgun"
      value -> String.downcase(String.trim(value))
    end

  mailer_config =
    case mailer_adapter do
      "gmail" ->
        gmail_access_token = System.get_env("GMAIL_API_ACCESS_TOKEN")
        gmail_client_id = System.get_env("GMAIL_CLIENT_ID")
        gmail_client_secret = System.get_env("GMAIL_CLIENT_SECRET")
        gmail_refresh_token = System.get_env("GMAIL_REFRESH_TOKEN")

        [
          adapter: Swoosh.Adapters.Gmail,
          from_email: mailer_from_email,
          from_name: mailer_from_name
        ]
        |> then(fn config ->
          cond do
            present?.(gmail_access_token) ->
              Keyword.put(config, :access_token, gmail_access_token)

            Enum.all?([gmail_client_id, gmail_client_secret], present?) ->
              config
              |> Keyword.put(:client_id, gmail_client_id)
              |> Keyword.put(:client_secret, gmail_client_secret)
              |> then(fn config ->
                if present?.(gmail_refresh_token) do
                  Keyword.put(config, :refresh_token, gmail_refresh_token)
                else
                  config
                end
              end)

            true ->
              raise """
              Gmail mailer configuration is incomplete.
              Set GMAIL_API_ACCESS_TOKEN, or set all of GMAIL_CLIENT_ID,
              and GMAIL_CLIENT_SECRET. GMAIL_REFRESH_TOKEN is only required
              until one has been persisted in the database.
              """
          end
        end)
        |> then(fn config ->
          case System.get_env("GMAIL_TOKEN_URL") do
            nil -> config
            "" -> config
            token_url -> Keyword.put(config, :token_url, token_url)
          end
        end)

      "mailgun" ->
        mailgun_api_key =
          System.get_env("MAILGUN_API_KEY") ||
            raise "environment variable MAILGUN_API_KEY is missing"

        mailgun_domain =
          System.get_env("MAILGUN_DOMAIN") ||
            raise "environment variable MAILGUN_DOMAIN is missing"

        [
          adapter: Swoosh.Adapters.Mailgun,
          api_key: mailgun_api_key,
          domain: mailgun_domain,
          from_email: mailer_from_email,
          from_name: mailer_from_name
        ]
        |> then(fn config ->
          case System.get_env("MAILGUN_BASE_URL") do
            nil -> config
            "" -> config
            base_url -> Keyword.put(config, :base_url, base_url)
          end
        end)

      other ->
        raise "MAILER_ADAPTER must be one of: gmail, mailgun. Got: #{inspect(other)}"
    end

  config :potok_ide, PotokIde.Mailer, mailer_config
end
