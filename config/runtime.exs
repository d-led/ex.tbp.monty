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
#     PHX_SERVER=true bin/ex_tbp_monty start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ex_tbp_monty, ExTbpMontyWeb.Endpoint, server: true
end

config :ex_tbp_monty, ExTbpMontyWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Which port a development or test run dials Postgres on. `docker-compose.yml`
# publishes it on a port of this project's own rather than the default one,
# because the default belongs to whichever container started first — on a machine
# with more than one project running, that is somebody else's database, and a
# `mix ecto.create` would land in it.
#
# `DB_PORT` moves both ends together when two checkouts of this one run at the
# same time. CI has no dev stack and its service is on the default port, so the
# test job sets `DB_PORT=5432` rather than relying on a default.
if config_env() in [:dev, :test] do
  config :ex_tbp_monty, ExTbpMonty.Repo,
    port: String.to_integer(System.get_env("DB_PORT", "6432"))
end

# Which world a run steps is the run's own choice: the run page's world
# selector, or `world` on `monty_run_experiment`. A run that says nothing steps
# the simulator in an external process, the way an experiment is meant to run;
# there is no deployment-wide override, because a world chosen per run is
# recorded on the run and that is the only place the answer belongs.

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :ex_tbp_monty, ExTbpMontyWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/ex_tbp_monty_web/router\.ex$"E,
        ~r"lib/ex_tbp_monty_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The database, decided here rather than at build time: Postgres when
  # `DATABASE_URL` names one, SQLite in a file otherwise, so the image runs as
  # one container and a deployment that has a database server says where it is.
  # Ecto binds an adapter to a repo when the repo is compiled, so the choice is
  # between two compiled repos and everything that needs one — the app, Oban,
  # the migrator — is given the same answer here.
  repo = ExTbpMonty.Database.repo_module()

  config :ex_tbp_monty, :repo, repo
  # What `mix ecto.*` would migrate if it were run inside the release: the same
  # answer the boot gives, rather than the Postgres this application was written
  # around.
  config :ex_tbp_monty, ecto_repos: [repo]
  config :ex_tbp_monty, repo, ExTbpMonty.Database.repo()
  config :ex_tbp_monty, Oban, repo: repo, engine: ExTbpMonty.Database.oban_engine()

  # Where the memory a run recognises with is kept. It is written at run time —
  # it is this application's export of Monty's pickles — so it belongs where a
  # container keeps things: on the same volume as the data the pickles came
  # from. Inside the release's own `priv` it is discarded with the container,
  # and every start exports every model again for nothing.
  config :ex_tbp_monty,
         :monty_libraries_dir,
         System.get_env("MONTY_LIBRARIES") ||
           Path.join(Monty.Prerequisites.root_path("MONTY_DATA"), "libraries")

  # What a first start needs and does not have is fetched in the background, not
  # in front of the server: the page stays responsive while a gigabyte arrives
  # and `/prerequisites` shows it. `PREFETCH=0` turns it off, for a deployment
  # that would rather fetch deliberately.
  config :ex_tbp_monty, prefetch: System.get_env("PREFETCH", "true") in ~w(true 1)

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

  config :ex_tbp_monty, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ex_tbp_monty, ExTbpMontyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ex_tbp_monty, ExTbpMontyWeb.Endpoint,
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
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ex_tbp_monty, ExTbpMontyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
