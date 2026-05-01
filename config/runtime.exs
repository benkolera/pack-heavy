import Config

# Build a Postgres URL from the four DATABASE_* env vars (host, user,
# password, name + optional port). Returns nil if any are missing.
# Used in prod when ECS injects parts via secrets references rather than
# a single URL — the ECS task wires DATABASE_PASSWORD from the RDS-managed
# SecretsManager secret using its `password` JSON key.
build_database_url = fn ->
  with host when is_binary(host) <- System.get_env("DATABASE_HOST"),
       user when is_binary(user) <- System.get_env("DATABASE_USER"),
       password when is_binary(password) <- System.get_env("DATABASE_PASSWORD"),
       name when is_binary(name) <- System.get_env("DATABASE_NAME") do
    port = System.get_env("DATABASE_PORT", "5432")
    encoded_pw = URI.encode_www_form(password)
    "ecto://#{user}:#{encoded_pw}@#{host}:#{port}/#{name}"
  else
    _ -> nil
  end
end

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
#     PHX_SERVER=true bin/packheavy start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :packheavy, PackheavyWeb.Endpoint, server: true
end

config :packheavy, PackheavyWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      build_database_url.() ||
      raise """
      environment variable DATABASE_URL is missing, and DATABASE_HOST /
      DATABASE_USER / DATABASE_PASSWORD / DATABASE_NAME aren't all set
      either. Provide DATABASE_URL directly (ecto://USER:PASS@HOST/DB)
      or set the four parts and we'll assemble it.
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # RDS Postgres rejects unencrypted connections. Verify the RDS
  # endpoint against AWS's global CA bundle (baked into the image at
  # /etc/ssl/certs/rds-global-bundle.pem by the runtime Dockerfile
  # stage) and pin the hostname via SNI so we catch any MITM.
  db_host =
    case URI.parse(database_url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> raise "Could not parse host from DATABASE_URL"
    end

  config :packheavy, Packheavy.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6,
    ssl: [
      cacertfile: "/etc/ssl/certs/rds-global-bundle.pem",
      verify: :verify_peer,
      server_name_indication: String.to_charlist(db_host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

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

  config :packheavy, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :packheavy, PackheavyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :packheavy,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # Auth0 (Google SSO via Auth0 Universal Login). All three env vars
  # are required in prod — the user.ex resource has the oauth2 :auth0
  # strategy compiled in unconditionally, so any missing config would
  # surface as a runtime auth failure rather than a clearer boot-time
  # error.
  auth0_domain =
    System.get_env("AUTH0_DOMAIN") ||
      raise("Missing environment variable `AUTH0_DOMAIN`!")

  auth0_client_id =
    System.get_env("AUTH0_CLIENT_ID") ||
      raise("Missing environment variable `AUTH0_CLIENT_ID`!")

  auth0_client_secret =
    System.get_env("AUTH0_CLIENT_SECRET") ||
      raise("Missing environment variable `AUTH0_CLIENT_SECRET`!")

  config :packheavy,
    auth0_base_url: auth0_domain,
    auth0_client_id: auth0_client_id,
    auth0_client_secret: auth0_client_secret,
    auth0_redirect_uri: "https://#{host}/auth"

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :packheavy, PackheavyWeb.Endpoint,
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
  #     config :packheavy, PackheavyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :packheavy, Packheavy.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
