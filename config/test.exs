import Config

# A test that steps a world steps this port's stand-in unless it says otherwise:
# the external process needs an interpreter with `tbp.monty` in it, which a test
# machine is not required to have. The production default is the other way
# round — see `Monty.Studio.Setup.configured_world/0`.
config :ex_tbp_monty, world_simulator: :synthetic

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ex_tbp_monty, ExTbpMonty.Repo.Postgres,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ex_tbp_monty_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ex_tbp_monty, ExTbpMontyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "8Bd/prwl6iHqjiAqUmWCkUO+CbXzRmzqme3yAWn0IYPB2zeiTBN+98YpQdVfkKYN",
  server: false

# Oban runs jobs by hand in tests, so a page test never races a queue.
config :ex_tbp_monty, Oban,
  testing: :manual,
  queues: false,
  plugins: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The replay's own clock. A test that presses play asks where playback starts,
# not how fast it is, and a timer that fires every 120 ms makes "it started at
# the first step" a test of the scheduler.
config :ex_tbp_monty, studio_replay_tick_ms: 5_000

# No catalogue parsing behind the suite's back: a test that lists experiments
# asks for them itself, and a warm-up racing it would only make both slower.
config :ex_tbp_monty, precompute: false
