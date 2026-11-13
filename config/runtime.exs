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

# The experiment's own trace (`Monty.Trace`): every step's own words, which is a
# lot of lines and is why they are off by default. `MONTY_TRACE=1` is how a shell
# asks for them, and they then arrive at `:debug` — so the console's level has to
# allow that too.
config :ex_tbp_monty_core,
  experiment_trace: System.get_env("MONTY_TRACE", "false") in ~w(true 1)

config :ex_tbp_monty, ExTbpMontyWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Clustering is a start-up decision, like the node's own name: `MONTY_CLUSTER=1`
# asks for the tree that joins a cluster, and `MONTY_SEEDS` names the nodes to
# join (`monty@10.0.0.7,monty2@10.0.0.8`). Either turns it on — a seed list alone
# is enough, because a list of nodes to dial is already the request. No seeds
# means gossip discovery, which is what several nodes on one machine need: they
# cannot know each other's names in advance.
#
# The names become atoms because that is what a node name is. This is
# configuration, read once at boot, not user input.
cluster_seeds =
  "MONTY_SEEDS"
  |> System.get_env("")
  |> String.split(",")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.map(&String.to_atom/1)

config :ex_tbp_monty, :cluster,
  enabled: System.get_env("MONTY_CLUSTER", "false") in ~w(true 1) or cluster_seeds != [],
  seeds: cluster_seeds

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
  # Set on the repo that actually starts. `ExTbpMonty.Repo` is the *delegating*
  # module — dev and test name `ExTbpMonty.Repo.Postgres` as the one this machine
  # runs, and a port written on the delegating module is inherited by nothing:
  # Postgrex then falls back to its own 5432, which on a machine with another
  # project's Postgres is somebody else's database.
  config :ex_tbp_monty, ExTbpMonty.Repo.Postgres,
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

# The window's sidecar: the same application as the image, with the storage one
# machine can have and one reader on loopback. Nothing here is a property of the
# build — it is what this launch decided, which is why it is not in
# `config/desktop.exs`.
if config_env() == :desktop do
  # One folder on one machine. Monty's own variable names are the mechanism —
  # this application, Monty's YAML resolvers (`${oc.env:MONTY_DATA}`) and the
  # embedded Python world all read them — so the folder is named once, here, and
  # nothing downstream needs a second answer. A variable somebody exported still
  # wins: `Monty.Paths` decides, and this writes back what it decided.
  for {variable, path} <- [
        {"MONTY_DATA", Monty.Paths.data()},
        {"MONTY_MODELS", Monty.Paths.models()},
        {"MONTY_LOGS", Monty.Paths.logs()},
        {"MONTY_LIBRARIES", Monty.Paths.libraries()},
        {"SQLITE_PATH", Monty.Paths.database()},
        {"WANDB_DIR", Monty.Paths.wandb()}
      ] do
    System.put_env(variable, path)
  end

  # Every directory the folders above name, made once. A download, a migration
  # and a run all expect their directory to exist and none of them owns making
  # it; `bin/server` makes `WANDB_DIR` before this VM starts, which is too early
  # to know where it is.
  for directory <- [
        Monty.Paths.root(),
        Monty.Paths.data(),
        Monty.Paths.models(),
        Monty.Paths.logs(),
        Monty.Paths.libraries(),
        Monty.Paths.artifacts(),
        Monty.Paths.wandb(),
        Path.dirname(Monty.Paths.database())
      ] do
    File.mkdir_p!(directory)
  end

  # The database is a file this launch just named, so the same predicate that
  # answers "which repo" answers "which engine" for Oban.
  repo = ExTbpMonty.Database.repo_module()

  config :ex_tbp_monty, :repo, repo
  config :ex_tbp_monty, ecto_repos: [repo]
  config :ex_tbp_monty, repo, ExTbpMonty.Database.repo()
  config :ex_tbp_monty, Oban, repo: repo, engine: ExTbpMonty.Database.oban_engine()

  # What a run leaves beside its record belongs beside the database, not inside
  # the release, which an installed application cannot write.
  config :ex_tbp_monty, :studio_artifacts_dir, Monty.Paths.artifacts()

  # The memory a run recognises with is exported at run time from the pickles
  # `MONTY_MODELS` holds, so it is user data of the same kind. This line was
  # under `config_env() == :prod` alone, and the desktop build therefore fell
  # back to `Memory.libraries_dir/0`'s `:code.priv_dir/1` — inside the `.app`:
  # every export written there went with the bundle when it was rebuilt, and an
  # installed copy cannot write one at all. So a second visit to a desktop
  # build found the memory a first visit had exported missing, and exported it
  # again.
  config :ex_tbp_monty, :monty_libraries_dir, Monty.Paths.libraries()

  # A first start has no data, and nothing is fetched in front of the window:
  # `/prerequisites` shows the download while it happens.
  config :ex_tbp_monty, prefetch: System.get_env("PREFETCH", "true") in ~w(true 1)

  # The window is one reader on loopback, so the signing salt is generated per
  # launch: a constant here would be a secret in a repository, and this
  # deployment has no place to fetch one from. Nothing is lost — the session it
  # signs belongs to the process serving it, and a cookie from the last launch
  # being unreadable changes nothing. The port is chosen as the application
  # starts (`ExTbpMonty.Desktop.Server`), because a fixed one belongs to whoever
  # bound it first.
  config :ex_tbp_monty, ExTbpMontyWeb.Endpoint,
    server: true,
    url: [host: "127.0.0.1", scheme: "http"],
    http: [ip: {127, 0, 0, 1}],
    secret_key_base: Base.encode64(:crypto.strong_rand_bytes(48))
end
