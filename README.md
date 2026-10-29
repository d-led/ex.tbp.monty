# ex.tbp.monty — Monty on the BEAM

A module-for-module reimplementation of the [Thousand Brains Project's
Monty](https://github.com/thousandbrainsproject/tbp.monty) in Elixir/Phoenix.

Three promises shape everything here:

1. **The same modules.** A Python file maps to an Elixir module by one rule
   ([docs/module-map.md](docs/module-map.md)), and a test fails when a Monty
   file has no entry.
2. **The same experiment configs.** Monty's Hydra/OmegaConf YAML is read
   unchanged; all 103 of Monty's committed config snapshots compose to the same
   tree here (`mix monty.config.snapshots`).
3. **Processes instead of a loop.** Sensor modules, learning modules and the
   motor system are BEAM processes exchanging CMP messages, so voting is a
   message round with an optional deadline rather than a blocking loop.

What has actually been compared against Monty — which numbers, how closely, and
what is still only a reading of the source — is in
[docs/validation.md](docs/validation.md).

The UI (LiveView + daisyUI) replaces hand-edited experiment configs and log
files: browse and edit an experiment, launch a run, watch the step log, the
hypothesis evidence and the vote telemetry as they happen.

## Status

| Piece | State |
| --- | --- |
| Phoenix app, Postgres/Ecto/Oban, quality gates, release tooling | done |
| `Monty.Cmp` — message, goal, attention region, wire form | done |
| `Monty.Config` — Hydra composition, resolvers, snapshot parity | done (103/103) |
| `Monty.ModuleMap` — the module contract and its verification | done (131 modules: Monty + teleop, 42 implemented) |
| `Monty.Runtime` — one process per sensor and learning module, step barriers, vote rounds with deadlines | done |
| Synthetic environment and `/runs/demo` live run view | done |
| `Monty.Prerequisites` — streaming downloads into Monty's data and model paths, `/prerequisites` view | done |
| `Monty.Studio` — faceted experiment index, setup preview and validation, builder, run history | done |
| Ported sensor/learning modules, evidence matching, motor policies | in progress — what agrees with Monty is listed in [docs/validation.md](docs/validation.md) |
| MuJoCo/Habitat bridge | planned (needs the simulator installed) |

## Quick start

```bash
docker compose up -d          # Postgres 17 on :6432
mix setup                     # deps, database, assets
mix phx.server                # http://localhost:4000
```

Monty's configs are read from a checkout of `tbp.monty`:

```bash
export MONTY_SOURCE=../monty-orig   # default; any tbp.monty checkout works
export TELEOP_SOURCE=../tbp.teleop # default; the teleop tool being replaced
```

## The studio

The application is a studio for Monty experiments, not a wrapper around one
script:

| Page | What it is for |
| --- | --- |
| `/` | every experiment Monty ships, faceted by agent, module count, learning module and starting point, with the filters in the URL |
| `/experiments/*name` | one experiment: its wiring diagram, what the checks say, the config, and a run that streams its steps and its log |
| `/build` | an experiment from the least input — a name is enough — previewed by composing the config it would write |
| `/runs` | every run, with the config snapshot and inputs it was given, its summary and its log; delete asks first |
| `/prerequisites` | the data and models an experiment needs, downloaded into Monty's own paths |

Runs are recorded in Postgres the moment they start: the composed config, the
inputs, the step log and the summary. Artifacts stay on the filesystem where
Monty puts them, so forgetting a run forgets its history, not its model.

Every page speaks Monty's vocabulary — sensor module, learning module,
`sm_to_lm_matrix`, epochs, votes — because the point is that a Monty developer
recognises the experiment and then notices the Elixir underneath it.

### Headless

The same experiments run without a browser, and are recorded the same way:

```bash
mix monty.run tutorial/first_experiment --steps 20
mix monty.run randrot_noise_10distinctobj_5lms_dist_agent --steps 200 --no-record --quiet
mix monty.bench tutorial/first_experiment randrot_noise_10distinctobj_5lms_dist_agent --repeat 5
```

`mix monty.run` exits non-zero when a config would not start. `mix monty.bench`
times this port's timestep loop on real experiment shapes — not Monty's accuracy
benchmarks (`benchmarks/*.csv`), which become comparable once the model modules
are ported — and its numbers are what a `:tprof` profile should start from.

## Prerequisites

Monty needs data and pretrained models before it can run an experiment. The
`/prerequisites` page fetches them into the same places Monty uses, so a run
started here finds the same files a run started from `run.py` would:

| Variable | Default | Holds |
| --- | --- | --- |
| `MONTY_DATA` | `~/tbp/data` | datasets such as YCB |
| `MONTY_MODELS` | `~/tbp/results/monty/pretrained_models` | pretrained models |
| `MONTY_LOGS` | `~/tbp/results/monty/projects` | experiment logs |

Downloads are streamed rather than buffered, so progress is shown as bytes
arrive and a cancel stops the transfer at once. Bytes land in `<target>.part`
and are renamed into place only when the transfer finished and the manifest's
checksum matched; a failed or cancelled attempt leaves nothing that looks
finished. The manifest is [priv/prerequisites.yaml](priv/prerequisites.yaml).

## Quality gates

```bash
mix ecto.migrate             # run history needs its table
scripts/quality.sh           # lint, the suite with coverage, the CRAP report
scripts/quality.sh --fast    # static analysis only
scripts/quality.sh --types   # ...and dialyzer (CI runs it as its own job)
mix lint                     # warnings-as-errors, unused deps, format, credo --strict, sobelow
mix cover                    # tests with coverage (threshold 85)
mix complexity               # CRAP: 20 for the ported core, 30 for the web layer
mix dialyzer                 # types, run as its own CI job
```

Two gates are specific to this project:

```bash
mix monty.config.snapshots   # compose all 103 experiments, compare to Monty's snapshots
mix monty.module_map.verify  # every Monty file is mapped, every "implemented" module exists
```

## Layout

```
lib/monty/            the port: CMP, geometry, config, module map, (next) runtime
lib/ex_tbp_monty/     the OTP application: repo, MCP server, release plumbing
lib/ex_tbp_monty_web/ Phoenix endpoint, LiveViews, components
priv/monty/           generated module map
docs/                 architecture, config compatibility, module map, MCP, developer notes
```

[docs/developers.md](docs/developers.md) is the entry point for working on the
code; [docs/architecture.md](docs/architecture.md) explains how a timestep
runs; [docs/roadmap.md](docs/roadmap.md) is the order the rest of Monty arrives
in — the numeric core first, then the world, then the numbers that make it
comparable. [docs/monty-bugs.md](docs/monty-bugs.md) lists what looks wrong in
Monty, and every place this port deliberately differs from it — read it before
diffing an Elixir run against a Python one, because some differences are
intended and some are upstream. [docs/mcp.md](docs/mcp.md) describes the MCP
server at `POST /mcp`,
which answers questions about Monty's docs, roadmap and code and can define and
run an experiment from a conversation.

## Licence

MPL-2.0. Monty itself is MIT-licensed; the module names and structure follow it
so the two can be read side by side.
