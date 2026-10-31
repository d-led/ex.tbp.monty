defmodule ExTbpMonty.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ex_tbp_monty,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      test_coverage: [summary: [threshold: coverage_threshold()]],
      package: package(),
      docs: docs(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {ExTbpMonty.Application, []},
      # os_mon answers "how much memory is left" and raises disk/memory alarms
      # for the runtime page: the same numbers the BEAM dashboard shows next to
      # the app's own heap.
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  def cli do
    [
      # The test-shaped aliases run against the test environment, the way
      # `mix test` itself does.
      preferred_envs: [cover: :test, complexity: :test, precommit: :test]
    ]
  end

  # Build-only Mix tasks live outside lib/ so the test environment (and the
  # types job) never sees them: they shell out to asset tooling that is only
  # present when an image is being built.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib", "mix_tasks"]

  # One run of the whole suite sees every line the suite can reach, so 85 is a
  # total. CI splits the suite across partitions and each sees a slice of it —
  # `COVERAGE_THRESHOLD=0` there — and the merged report (`mix test.coverage`)
  # holds the total to this number, exactly as one local run does.
  defp coverage_threshold do
    case System.get_env("COVERAGE_THRESHOLD") do
      value when value in [nil, ""] -> 85
      value -> String.to_integer(value)
    end
  end

  defp package do
    [
      licenses: ["MPL-2.0"],
      description:
        "Thousand Brains Project Monty reimplemented on the BEAM: the same modules, " <>
          "the same experiment configs, cortical columns as processes."
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/developers.md",
        "docs/container.md",
        "docs/architecture.md",
        "docs/config-compatibility.md",
        "docs/module-map.md"
      ]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      {:phoenix_test, "~> 0.13.1", only: :test, runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.7.9",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      # Monty's experiment configs are Hydra/OmegaConf YAML. Reading them
      # unchanged is the compatibility promise, so the parser is a real
      # dependency rather than a hand-rolled subset.
      {:yaml_elixir, "~> 2.11"},
      # Monty's loggers call the Python `wandb` client, and this is how the port
      # reaches Python without an external interpreter to install or keep in step:
      # an embedded runtime the application manages itself.
      {:pythonx, "~> 0.4.11"},
      {:oban, "~> 2.20"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3.1"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts",
      plt_local_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit],
      # The types job is about the application: Mix tasks are operator tooling
      # whose contract is the command line, and tests are exercised by running
      # them. Warnings there would drown the signal.
      exclude_paths: ["lib/mix/tasks/**", "test/**"],
      flags: [:error_handling, :extra_return, :missing_return]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "monty.inputs --warn-only", "assets.setup", "assets.build"],
      # Migrations come in two directories: the ones that must run on deploy and
      # the manual ones (slow, destructive, data). Dev and test want both.
      "ecto.migrate_all":
        "ecto.migrate --migrations-path=priv/repo/migrations --migrations-path=priv/repo/manual_migrations",
      "ecto.setup": ["ecto.create", "ecto.migrate_all", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate_all --quiet", "test"],
      "assets.setup": ["assets.install --if-missing"],
      "assets.build": [
        "cmd --cd assets npm ci",
        "compile",
        "tailwind ex_tbp_monty",
        "esbuild ex_tbp_monty"
      ],
      "assets.deploy": [
        "cmd --cd assets npm ci",
        "tailwind ex_tbp_monty --minify",
        "esbuild ex_tbp_monty --minify",
        "phx.digest"
      ],
      # Static analysis: no database, no test run, under a few seconds. Read-only
      # on purpose — a check that rewrites files cannot run in CI.
      lint: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "lint.sobelow --config"
      ],
      # Tests with the coverage data the complexity gate needs.
      cover: ["test --cover --export-coverage default"],
      # CRAP scores every function by complexity and coverage; it reads the
      # exported coverage, so it runs after `mix cover`. The numeric core is held
      # to a stricter threshold than the web layer, because its functions are
      # where correctness lives.
      #
      # `cmd` on purpose: Mix refuses to run a task twice in one invocation, so
      # two plain `crap` entries would silently check only the first path.
      complexity: [
        "cmd mix crap --path lib/monty --max-score 20 --verbose",
        "cmd mix crap --path lib/ex_tbp_monty --max-score 20 --verbose",
        "cmd mix crap --path lib/ex_tbp_monty_web --max-score 30 --verbose"
      ],
      # What CI runs: the report script, which chains lint, cover and complexity
      # and prints one summary. `mix lint` and `mix cover` stay available alone.
      precommit: ["cmd scripts/quality.sh"]
    ]
  end
end
