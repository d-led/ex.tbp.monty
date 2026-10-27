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

The UI (LiveView + daisyUI) replaces hand-edited experiment configs and log
files: browse and edit an experiment, launch a run, watch the step log, the
hypothesis evidence and the vote telemetry as they happen.

## Status

| Piece | State |
| --- | --- |
| Phoenix app, Postgres/Ecto/Oban, quality gates, release tooling | done |
| `Monty.Cmp` — message, goal, attention region, wire form | done |
| `Monty.Config` — Hydra composition, resolvers, snapshot parity | done (103/103) |
| `Monty.ModuleMap` — the module contract and its verification | done (124 modules, 2 implemented) |
| Actor runtime (`Monty.Runtime.*`), synthetic environment | next |
| Evidence matching, voting, motor policies, MuJoCo bridge, UI | planned |

## Quick start

```bash
docker compose up -d          # Postgres 17 on :6432
mix setup                     # deps, database, assets
mix phx.server                # http://localhost:4000
```

Monty's configs are read from a checkout of `tbp.monty`:

```bash
export MONTY_SOURCE=../monty-orig   # default; any tbp.monty checkout works
```

## Quality gates

```bash
scripts/quality.sh           # lint, the suite with coverage, the CRAP report
scripts/quality.sh --fast    # static analysis only
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
lib/ex_tbp_monty/     the OTP application: repo, release plumbing
lib/ex_tbp_monty_web/ Phoenix endpoint, LiveViews, components
priv/monty/           generated module map
docs/                 architecture, config compatibility, module map, developer notes
```

[docs/developers.md](docs/developers.md) is the entry point for working on the
code; [docs/architecture.md](docs/architecture.md) explains how a timestep
runs.

## Licence

MPL-2.0. Monty itself is MIT-licensed; the module names and structure follow it
so the two can be read side by side.
