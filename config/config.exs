# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ex_tbp_monty,
  ecto_repos: [ExTbpMonty.Repo.Postgres],
  generators: [timestamp_type: :utc_datetime]

# `Ecto.Migrator.migrations_path/2` builds the directory from the repo module's
# own name — `priv/<last word, underscored>/migrations`, which is why this
# project's migrations sit in `priv/repo`: the module was called `Repo`. The
# repos are `Repo.Postgres` and `Repo.SQLite` now, so the directory is named
# rather than inherited from a module name — with the `priv/` prefix, which is
# what that option is expected to carry (its default is `priv/repo`).
# Ecto logs every statement at `:debug`, which is the level a development console
# shows. A page following a run reads the database on a timer, so that log is
# thousands of lines nobody asked for — and it would have made adding `:debug` to
# the console the same mistake the experiment's own per-step lines were. A
# console that wants the statements says `log: :debug` here.
config :ex_tbp_monty, ExTbpMonty.Repo.Postgres,
  priv: "priv/repo",
  log: false,
  # How long a caller may hold a connection before DBConnection gives up on it.
  # The default is fifteen seconds, and every episode boundary writes the run's
  # transcript back into its row (`RunHistory.append_steps/4` appends to a jsonb
  # array, which rewrites the array) — a write that outgrew the default and took
  # the run's job down with it:
  #
  #     (DBConnection.ConnectionError) client #PID<…> (Monty.Studio.Jobs.Run)
  #     timed out because it queued and checked out the connection for longer
  #     than 15000ms
  #
  # Two minutes of patience made that worse, not better: while the write waits it
  # holds a connection, the page's reads queue behind it, and the socket misses
  # enough heartbeats to drop. Thirty seconds is long enough for the write that
  # succeeds, short enough that the one that will not is given up on — the job
  # treats that as a retry at the next boundary rather than as the end of the run
  # (`Jobs.Run.keep_with_state/1`). It is still a stop-gap: append-only step rows
  # make the write O(episode) and this number irrelevant.
  timeout: 30_000,
  queue_target: 1_000,
  queue_interval: 10_000

config :ex_tbp_monty, ExTbpMonty.Repo.SQLite, priv: "priv/repo", log: false

# Where this software lives: the footer links to it with the octocat. A fork
# that does not want the upstream link drops the key, and the link goes with it.
config :ex_tbp_monty, :source, repo: "https://github.com/d-led/ex.tbp.monty"

# What wandb does. wandb's own default is `online`: a config that names a wandb
# logger would try to sync a run the moment it starts, which is not something a
# local deployment should do because nobody said otherwise. So the default here
# is `disabled`, the environment (`WANDB_MODE`, read at run time — see
# `ExTbpMonty.EmbeddedPython.wandb_mode/0`) wins over it, and what it answers is
# what the interpreter is told before `wandb.init`, so the two cannot disagree.
config :ex_tbp_monty, wandb_mode: "disabled"

# The experiment's own words — what Monty's Python prints per step and per module
# (`Monty.Trace`) — are off unless a deployment asks for them: a run says "did not
# recognize an object yet" on every step, and a console reading a twenty-thousand
# step run is a console nobody can read. `MONTY_TRACE=1` turns them on at run time
# (`config/runtime.exs`); nothing else here is gated that way.
config :ex_tbp_monty_core, experiment_trace: false

# Which world a run steps when nobody chooses one. MuJoCo is the world Monty's
# own configs are written for, and it costs nothing here: the interpreter that
# renders it travels with the application (`config/pythonx.exs`), so a checkout
# and a container run the same experiment without anyone installing anything.
# The stand-in scene is the other choice, and what the suite uses — it needs no
# scene description and no interpreter.
config :ex_tbp_monty, world_simulator: :mujoco

# "Is MuJoCo here?" is answered by the interpreter this application carries, not
# by whatever `python3` the PATH offers: `config/pythonx.exs` is where the build
# installs packages into it, so the answer is a property of the deployment. A
# test or a script that has no such interpreter drops the key and gets the
# subprocess check (`Monty.Prerequisites.importable_in_environment/1`).
config :ex_tbp_monty, python_imports?: {ExTbpMonty.EmbeddedPython, :imports?}

# Configure the endpoint
config :ex_tbp_monty, ExTbpMontyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ExTbpMontyWeb.ErrorHTML, json: ExTbpMontyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ExTbpMonty.PubSub,
  live_view: [signing_salt: "64S1tVHa"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ex_tbp_monty: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  ex_tbp_monty: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
#
# The metadata allow-list is the point: a line carries the identifiers a reader
# needs to follow one run (or one download, or one job) through the log, and
# nothing else. Anything not listed is dropped rather than printed as noise.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :experiment,
    :run_id,
    :job_id,
    :download_id,
    :module,
    :sensor,
    :step,
    :status,
    :reason,
    :duration_us
  ]

# Phoenix logs every request and cannot be told to skip one; the replacement is
# `ExTbpMontyWeb.Telemetry.RequestLog`, which logs one line per request and
# nothing for the health probe.
config :phoenix, :logger, false

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Experiment runs are jobs: a run that is queued survives the page that queued
# it, and what it did lives in `studio_runs` rather than in a LiveView's memory.
# Two at a time is a person's attention span, not a throughput decision.
#
# A start fetches, in the background, every prerequisite with work left in it:
# the pages answer while bytes arrive, `/prerequisites` shows each one, and a
# machine that is already whole only re-checks its memory. `PREFETCH=0` (or
# `false` here) turns it off for a deployment that would rather fetch
# deliberately; the suite turns it off because a test that downloads is not a
# test.
config :ex_tbp_monty, prefetch: true

config :ex_tbp_monty, Oban,
  engine: Oban.Engines.Basic,
  repo: ExTbpMonty.Repo.Postgres,
  queues: [studio: 2]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# The Python interpreter Monty's wandb loggers run in, in every environment.
import_config "pythonx.exs"

import_config "#{config_env()}.exs"
