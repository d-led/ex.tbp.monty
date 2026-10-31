# ex.tbp.monty — Monty on the BEAM

A module-for-module reimplementation of the [Thousand Brains Project's
Monty](https://github.com/thousandbrainsproject/tbp.monty) in Elixir/Phoenix.

Three promises shape everything here:

1. **Same modules.** Python `path/file.py::Class` becomes
   `Monty.Path.File.Class` by one rule
   ([docs/module-map.md](docs/module-map.md)), and
   `mix monty.module_map.verify` fails when a Monty file has no entry.
2. **Same configs.** Monty's Hydra/OmegaConf YAML is read unchanged; all 103
   committed snapshots compose to the same tree here
   (`mix monty.config.snapshots`).
3. **Processes, not a loop.** Sensors, learning modules and the motor system are
   BEAM processes exchanging CMP messages, so voting is a message round with a
   deadline rather than a blocking loop.

**Believe the receipts, not the claims.** What has actually been compared with
Monty — which numbers, how closely, what is still only a reading of the source —
is [docs/validation.md](docs/validation.md). Every deliberate difference is
[docs/monty-bugs.md](docs/monty-bugs.md); read it before diffing an Elixir run
against a Python one.

## TL;DR

```bash
docker compose up -d     # Postgres 17 on :6432
mix setup                # deps, database, assets
mix phx.server           # http://localhost:4000
```

No browser needed: `mix monty.run tutorial/first_experiment --steps 20`.

The UI (LiveView + daisyUI) replaces hand-edited configs and log files: browse
and edit an experiment, launch a run, watch the step log, the hypothesis
evidence and the vote telemetry as they happen.

## Status

| Piece | State |
| --- | --- |
| Phoenix app, Postgres/Ecto/Oban, quality gates, release tooling | done |
| `Monty.Cmp` — message, goal, attention region, wire form | done |
| `Monty.Config` — Hydra composition, resolvers, snapshot parity | done (103/103) |
| `Monty.ModuleMap` — the module contract and its verification | done — 131 modules, 47 implemented |
| `Monty.Runtime` — one process per sensor and learning module, step barriers, vote rounds with deadlines | done |
| Synthetic world (`Monty.Simulators.Synthetic.*`) and its camera frames | done |
| `Monty.Prerequisites` — streaming downloads into Monty's own data and model paths, `/prerequisites` view | done |
| `Monty.Studio` — faceted index, setup preview and validation, builder, run history, job queue | done |
| Ported sensor/learning modules, evidence matching, motor policies | in progress — see [docs/validation.md](docs/validation.md) |
| MuJoCo/Habitat world | Elixir side done (`Monty.Simulators.Port.*`); the Python peer is not — [docs/simulator-port.md](docs/simulator-port.md) |

The counts are a snapshot; `mix monty.module_map.verify` prints the current ones.

## Configure the checkouts

Monty's configs — and the module map — are read from checkouts:

```bash
export MONTY_SOURCE=../monty-orig   # default; any tbp.monty checkout works
export TELEOP_SOURCE=../tbp.teleop # default; the teleop tool being replaced
```

The config tests need `MONTY_SOURCE`, the module map needs both. Without them
they fail rather than pass quietly.

## The studio

The application is a studio for Monty experiments, not a wrapper around one
script:

| Page | What it is for |
| --- | --- |
| `/` | every experiment Monty ships, faceted by agent, module count, learning module and starting point — the filters live in the URL |
| `/experiments/*name` | one experiment: wiring diagram, what the checks say, the config, and a run that streams steps and log |
| `/build` | an experiment from the least input — a name is enough — previewed by composing the config it would write |
| `/runs` | every run with its config snapshot, inputs, summary and log; delete asks first |
| `/runs/:id` | one run, replayed: what each step saw, the evidence it climbed to, and why it stopped |
| `/jobs` | the Oban queue — what is waiting, what failed and why, and where a job that will not finish is cancelled or killed |
| `/prerequisites` | the data and models an experiment needs, downloaded into Monty's own paths |

Runs are recorded in Postgres the moment they start — composed config, inputs,
step log, summary. Artifacts stay on the filesystem where Monty puts them, so
forgetting a run forgets its history, not its model.

Every page speaks Monty's vocabulary — sensor module, learning module,
`sm_to_lm_matrix`, epochs, votes — so a Monty developer recognises the
experiment and then notices the Elixir underneath it.

### Headless

Same experiments, no browser, recorded the same way:

```bash
mix monty.run tutorial/first_experiment --steps 20
mix monty.run randrot_noise_10distinctobj_5lms_dist_agent --steps 200 --no-record --quiet
mix monty.bench tutorial/first_experiment randrot_noise_10distinctobj_5lms_dist_agent --repeat 5
```

* `mix monty.run` — `--steps N` (default 12), `--seed N`,
  `--record`/`--no-record`, `--quiet`. Recorded by default, so a headless run
  turns up in `/runs`. Exits 1 when the config would not start, so it is usable
  from CI.
* `mix monty.bench` — `--steps N`, `--repeat N` (reported as the median),
  `--json`. Times **this port's timestep loop** — supervision, barriers, the vote
  round, reporting — not accuracy; Monty's `benchmarks/*.csv` only become
  comparable once the model modules are ported. Nothing is recorded. Its numbers
  are what a `:tprof` profile should start from.

## Prerequisites

Monty needs data and pretrained models before it can run. `/prerequisites`
fetches them into the same places Monty uses, so a run started here finds the
same files a run started from `run.py` would:

| Variable | Default | Holds |
| --- | --- | --- |
| `MONTY_DATA` | `~/tbp/data` | datasets such as YCB |
| `MONTY_MODELS` | `~/tbp/results/monty/pretrained_models` | pretrained models |
| `MONTY_LOGS` | `~/tbp/results/monty/projects` | experiment logs |

* Downloads are **streamed**, so progress is bytes arriving and a cancel stops
  the transfer at once.
* Bytes land in `<target>.part`, and are renamed into place only when the
  transfer finished *and* the manifest's checksum matched. A failed or cancelled
  attempt leaves nothing that looks finished.
* The manifest is [priv/prerequisites.yaml](priv/prerequisites.yaml).

## Quality gates

```bash
mix precommit                 # everything CI runs (scripts/quality.sh)
scripts/quality.sh            # lint, the suite with coverage, the CRAP report
scripts/quality.sh --fast     # static analysis only
scripts/quality.sh --no-tests # reuse the exported coverage, re-rank only
scripts/quality.sh --types    # ...and dialyzer (CI runs it as its own job)
mix lint                      # warnings-as-errors, unused deps, format, credo --strict, sobelow
mix cover                     # tests with coverage (threshold 85)
mix complexity                # CRAP: 20 for the ported core, 30 for the web layer
mix dialyzer                  # types, run as its own CI job
```

Two gates are specific to this project:

```bash
mix monty.config.snapshots   # compose all 103 experiments, compare with Monty's snapshots
mix monty.module_map.gen     # rewrite lib/monty/module_map/data.ex from the checkouts
mix monty.module_map.verify  # every Monty file is mapped, every "implemented" module exists
```

**The module map is generated, not hand-written.**
`lib/monty/module_map/data.ex` holds one entry per Python file: the Elixir module
it maps to, a status, and its classes. `gen` re-derives all of it and flips an
entry to `implemented` by loading the Elixir module; only human decisions
(`excluded` plus a reason, `excluded_classes`) survive a regeneration, and
`--reset-decisions` throws even those away.

`verify` fails on a Monty file with no entry, an `implemented` entry whose
module is missing, or an `excluded` entry with no reason. It does **not** diff
the committed file against a fresh `gen`, so run `gen` after writing a module.

## Container image

Each commit that passes the gates above is published to
`ghcr.io/d-led/ex.tbp.monty`, under the name of the ref it was built from:

| Built from | Tags |
| --- | --- |
| a push to `main` | `:main` and `:latest` |
| a push to any other branch | `:<branch>` — `feature/x` becomes `:feature-x` |
| a tag `v1.2.3` | `:v1.2.3`, amd64 **and** arm64; a branch is amd64 only |

There are no commit-hash tags: the image carries its commit instead.
`mix build.info` writes it into the release, and the footer of every page shows
it — `main+3f2a1c9` — with the whole build (commit, time, the pipeline run that
produced it) in its tooltip, and the octocat beside it linking here.

```bash
docker pull ghcr.io/d-led/ex.tbp.monty:latest

# Once per deploy: the release expects its tables to exist.
docker run --rm -e DATABASE_URL=... -e SECRET_KEY_BASE=... \
  ghcr.io/d-led/ex.tbp.monty:latest /app/bin/migrate

# The app itself, unprivileged, with the one writable directory on a volume and
# nothing else writable at all — which is how it is meant to run.
docker run --rm -p 4000:4000 \
  --read-only --tmpfs /tmp \
  -v monty-priv:/app/priv \
  -e DATABASE_URL=... -e SECRET_KEY_BASE=... \
  ghcr.io/d-led/ex.tbp.monty:latest   # /app/bin/server
```

The image runs as **uid 10001** and needs no privilege of any kind — no root, no
writable filesystem outside the volume. `CI` scans it with Trivy before pushing,
and the publishing job starts it as that uid. [docs/container.md](docs/container.md)
is the operator's page: every variable the release reads, what is on the volume,
where the data and models come from, and what the app reports about itself.
From a checkout, `scripts/image.sh build` → `run` → `smoke` → `publish` does the
same work under the same image name.

One directory is writable, `/app/priv`, and everything that writes is pointed
at it, because a release resolves those paths somewhere else: the studio's
drafts and a run's files as `priv/…` relative to the working directory (the
release's `bin/`, which is why `/app/bin/priv` is a symlink), Monty's downloads
at `~/tbp`, wandb's runs at `$WANDB_DIR`. `HOME=/app/priv` and
`WANDB_DIR=/app/priv/wandb` are the defaults the image sets, and both can be
overridden with `-e`.

That directory has to belong to uid 10001, and the image cannot arrange it —
giving ownership away needs root, which is the thing it does not have. A named
Docker volume inherits it from the image and works as is; a Kubernetes PVC needs
`fsGroup: 10001`; a bind mount or a tmpfs needs a `chown 10001:10001` once. When
it is wrong the release says so at boot (`the release cannot write
/app/priv/wandb …`) instead of failing quietly, and wandb falls back to the
system temp directory. Mount a volume at `/app/priv` either way, or a restart
takes drafts, run logs and downloads with it.

The embedded Python (pythonx) needs nothing installed on the host: the
interpreter, its packages and the uv that built them travel inside the image,
in the release's `lib/pythonx-*/priv`.

## Layout

```
lib/monty/               the port: CMP, config, geometry, models, runtime, studio
lib/monty/runtime/       processes only — step barriers, vote rounds, routing
lib/monty/studio/        experiments, setups, run history (the app's domain)
lib/monty/simulators/    the world: synthetic, port protocol, recordings
lib/ex_tbp_monty/        the OTP application: repo, MCP server, release plumbing
lib/ex_tbp_monty_web/    Phoenix endpoint, LiveViews, components
priv/monty/              generated module map, exported pretrained libraries
priv/prerequisites.yaml  what a run downloads, checksummed
docs/                    architecture, config compatibility, module map, MCP, validation
```

## Where to read next

| Doc | Answers |
| --- | --- |
| [docs/developers.md](docs/developers.md) | how do I work on this? invariants, tests, gates — **start here** |
| [docs/container.md](docs/container.md) | how do I run the image? every variable, the volume, what it reports |
| [docs/architecture.md](docs/architecture.md) | what happens in one timestep? |
| [docs/module-map.md](docs/module-map.md) | where is that Python file here? |
| [docs/config-compatibility.md](docs/config-compatibility.md) | which Hydra features are implemented, and how far parity goes |
| [docs/validation.md](docs/validation.md) | what has been compared with Monty, and how closely |
| [docs/monty-bugs.md](docs/monty-bugs.md) | what looks wrong upstream, and every deliberate difference |
| [docs/simulator-port.md](docs/simulator-port.md) | where the world lives, and what is still Python |
| [docs/parallel-and-live.md](docs/parallel-and-live.md) | parallel episodes and a live world — designed, not built |
| [docs/roadmap.md](docs/roadmap.md) | the order the rest of Monty arrives in |
| [docs/open-ends.md](docs/open-ends.md) | everything TBP and its community say is still open, as a menu to pick from |
| [docs/mcp.md](docs/mcp.md) | `POST /mcp` — ask this app about Monty's docs, roadmap and code, and define and run an experiment from a conversation |

## Licence

MPL-2.0. Monty itself is MIT-licensed; the module names and structure follow it
so the two can be read side by side.
