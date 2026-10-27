# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ex_tbp_monty,
  ecto_repos: [ExTbpMonty.Repo],
  generators: [timestamp_type: :utc_datetime]

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
config :ex_tbp_monty, Oban,
  engine: Oban.Engines.Basic,
  repo: ExTbpMonty.Repo,
  queues: [studio: 2]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
