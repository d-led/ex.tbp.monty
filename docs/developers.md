# Developing Monty on the BEAM

Working on the code: invariants, the module contract, tests and gates.
Deployment and operations live in the Dockerfile and `rel/`.

## To whom it may concern

This is a reimplementation, not a fork. Monty's Python is the reference for
behaviour, names, units and config shape; the BEAM is where it runs. Nothing
here is allowed to *drift* from that, and nothing keeps it in step by memory:
each kind of drift has a command that fails when it happens. Starting cold,
trust those commands rather than any prose, including this page.

The loop is the same for every change:

```bash
mix test                      # the suite alone; creates and migrates the test database
scripts/quality.sh --fast     # lint only: compile, format, credo, sobelow — seconds
scripts/quality.sh            # lint, cover, CRAP — what CI runs
```

Behaviour first: a test that says what the port decides, then the port, then the
gate. A test that asserts the implementation is what it is has bought nothing.

### When Monty moves

A pull, a new release, or a checkout of a newer Monty all arrive the same way.
Work through this in order; each step tells you whether the next one matters.

```bash
export MONTY_SOURCE=../monty-orig      # the default; any checkout works
mix monty.inputs                       # fast-forward main, then copy conf + snapshots
mix monty.inputs --check               # read-only: is priv/monty what that checkout holds?
mix monty.config.snapshots             # composes every config, compares tree to snapshot
mix monty.module_map.gen               # new, renamed and deleted Python files
mix monty.module_map.verify            # every file mapped, every implemented entry real
mix monty.port_census                  # what the newly planned classes actually are
```

1. **Inputs.** `mix monty.inputs` only ever fast-forwards `main`, and only when
   the checkout is on `main` with nothing uncommitted; anything else is reported
   and left alone, because a copy taken from a tree that is not what it claims to
   be is worse than a stale copy. The revision is recorded in
   [`priv/monty/inputs.json`](../priv/monty/inputs.json) (`monty`, `conf_files`,
   `snapshot_files`) — that file is the answer to "which Monty is this?", and it
   moves with the copy.
2. **Configs.** `mix monty.config.snapshots` is the compatibility gate: it
   composes each experiment from the YAML in [`priv/monty/conf`](../priv/monty/conf)
   and compares the
   result with Monty's own `tests/conf/snapshots`, path by path. A missing key is
   as much a difference as a wrong value, and "close enough" is how a config
   quietly means something else. Add `--source ../monty-orig` to check a
   checkout whose copy you have not refreshed yet.
3. **Files.** `mix monty.module_map.gen` (re)writes
   [`lib/monty/module_map/data.ex`](../lib/monty/module_map/data.ex)
   from both packages: every Python file, the Elixir module its path maps to, its
   classes, and whether that module exists. An entry already marked `excluded`
   with a reason stays excluded; an entry whose module now exists becomes
   `implemented`. `mix monty.module_map.verify` then fails on a Python file with
   no entry, an `implemented` entry with no module, or an `excluded` entry
   without a reason, and reports a checkout that has moved since the map was
   generated.
4. **Scope.** Before writing anything, `mix monty.port_census` says what each
   still-planned class *is* in Monty — a `Protocol`, an `ABC` whose methods raise,
   a `TypedDict`, or a dataclass that does arithmetic. Only the last is a module
   to port; the counts it prints are the honest backlog, not a "classes remaining"
   number.
5. **Behaviour.** Read what changed before porting it. [`monty-bugs.md`](monty-bugs.md)
   records the places where Monty looks wrong and what this port does instead,
   with the reason; [`open-ends.md`](open-ends.md) records what upstream says is
   not done; [`validation.md`](validation.md) is what has actually been checked
   against Monty's numbers, and a claim that is not there is not a claim.
6. **Port.** Add the module under the name the map gives it, as pure functions,
   with a test that says what it decides — and where numbers matter, against a
   fixture recorded from Monty (`scripts/record_monty_*.py` run Monty in Monty's
   environment and write what it answered; the suite replays that JSON).
7. **Gate.** [`scripts/quality.sh`](../scripts/quality.sh), and `mix dialyzer`
   for the types job.

### Where to look

| Question | Look at |
| --- | --- |
| Where would Monty's `a/b.py::C` live here? | [`lib/monty/module_map/data.ex`](../lib/monty/module_map/data.ex), rule in [`module-map.md`](module-map.md) |
| Is this ported, planned or excluded? | the same entry's `status`; `mix monty.port_census` for what planned means |
| Does this config still mean what Monty means? | [`config-compatibility.md`](config-compatibility.md), then `mix monty.config.snapshots` |
| How does a timestep run, and where is Python involved? | [`architecture.md`](architecture.md) — and [what is Python here](#what-is-python-here-and-what-it-does) below |
| What does the world boundary allow? | [`simulator-port.md`](simulator-port.md) |
| Which files are Monty's, copied, and which are ours? | [`architecture.md`](architecture.md#what-comes-from-monty), section "What comes from Monty"; [`priv/monty/README.md`](../priv/monty/README.md) |
| How do I refresh Monty's YAML, snapshots or memories? | `mix monty.inputs`, [`scripts/sync_monty_libraries.sh`](../scripts/sync_monty_libraries.sh) |
| Why does this disagree with Python? | [`monty-bugs.md`](monty-bugs.md) |
| What is actually proven? | [`validation.md`](validation.md) and [`test/fixtures/`](../test/fixtures) |
| What is not built yet? | [`roadmap.md`](roadmap.md), [`open-ends.md`](open-ends.md) |
| Which Monty is this repo pinned to? | [`priv/monty/inputs.json`](../priv/monty/inputs.json) |
| Which build am I looking at? | `priv/build_info.json` (written by `mix build.info`), also in the footer of every page |
| How does it run in a container? | [`container.md`](container.md), [`Dockerfile`](../Dockerfile) |

### What not to do

- **Do not rename a mapped module** to a prettier Elixir name, and do not
  collapse the one-to-one structure. Finding Monty's file is the feature.
- **Do not add a config key, resolver or default Monty's `conf/` does not use.**
  If a value is missing, the finding is that the copy is stale, not that the
  resolver should be generous.
- **Do not regenerate the copy from a dirty or non-`main` checkout**, and do not
  edit [`priv/monty`](../priv/monty) by hand. The YAML has exactly one writer,
  `mix monty.inputs`; the memories have one,
  [`scripts/sync_monty_libraries.sh`](../scripts/sync_monty_libraries.sh); the two
  census files are written by the tasks that produce them (`mix monty.port_census`,
  `mix monty.target_census`) and are otherwise read-only.
- **Do not paper over a disagreement.** A run that "works" with a stand-in module
  is worse than a run that refuses: an unimplemented class is an error, never a
  substitute. A deliberate difference goes in [`monty-bugs.md`](monty-bugs.md)
  with a reason.
- **Do not let a number live in prose.** Counts belong to the command that
  prints them (`mix monty.port_census`, `mix monty.module_map.verify`, and
  [`scripts/refresh_features.py`](../scripts/refresh_features.py) for
  [`features.md`](features.md)), because a number copied into a sentence is
  wrong by the next commit.

## Local setup

```bash
scripts/init-dev.sh    # Postgres in Docker, dependencies, database, assets
scripts/run-dev.sh     # http://localhost:4000
```

[`scripts/init-dev.sh`](../scripts/init-dev.sh) needs Elixir 1.20 with the OTP it
runs on, node/npm for the asset bundle, and Docker for the Postgres
[`config/dev.exs`](../config/dev.exs) expects on port 6432; it runs
`docker compose -f docker-compose.dev.yml up -d` and `mix setup`, and is worth
running again after a pull
that moves a dependency or a migration. [`scripts/run-dev.sh`](../scripts/run-dev.sh)
is `mix phx.server` with the code reloader — `PORT=4001 scripts/run-dev.sh` moves
it, and `MONTY_WORLD=monty MONTY_PYTHON=… scripts/run-dev.sh` steps Monty's own
simulator instead of the synthetic scene.

Tests need the same database; `mix test` creates and migrates it.

## Where the code is

```
lib/monty/               the port, one module per Monty file: cmp, config, geometry,
                         frameworks/, experiment/, sensor_modules/, random/
lib/monty/runtime/       processes only — step barriers, vote rounds, routing
lib/monty/studio/        experiments, setups, run history (the app's domain)
lib/monty/simulators/    the world: synthetic, port protocol, recordings, the Habitat handle
lib/ex_tbp_monty/        the OTP application: repo, MCP server, release plumbing
lib/ex_tbp_monty_web/    Phoenix endpoint, LiveViews, components
priv/monty/              Monty's config tree, snapshots and licence, verbatim; exported memories
priv/experiments/        experiment files the studio writes (a draft is a config, not a row)
priv/studio_runs/        what each run wrote: run.log, frames, logs (ignored by git)
priv/prerequisites.yaml  what a run downloads, checksummed
scripts/                 the gates, the dev scripts, and every Python file this project has
mix_tasks/               Mix tasks compiled outside `:test` (assets, build info)
THIRD-PARTY.md           what this project did not write, and under which terms
docs/                    architecture, config compatibility, module map, MCP, validation
```

The one directory that is not code is [`priv/monty`](../priv/monty): it is
Monty's data, copied rather than written — `mix monty.inputs` for the YAML,
[`scripts/sync_monty_libraries.sh`](../scripts/sync_monty_libraries.sh) for the
pretrained memories. [`architecture.md`](architecture.md#what-comes-from-monty)
lists it beside the things that are *not* copied.

## What is Python here, and what it does

Only the world and the recorders. Nothing of Monty's own source is vendored:

| Python | What it is | Needs |
| --- | --- | --- |
| [`scripts/monty_simulator_peer.py`](../scripts/monty_simulator_peer.py) | Monty's `HabitatEnvironment` and eval interface, behind the port's protocol — the world a run steps when `MONTY_WORLD=monty` | `$MONTY_PYTHON` with `tbp.monty` and its simulator installed |
| [`scripts/record_monty_*.py`](../scripts) | produce the fixtures the parity tests replay; run Monty once, offline, and write what it answered | `$MONTY_PYTHON` with the modules each recorder touches |
| [`scripts/export_monty_pretrained.py`](../scripts/export_monty_pretrained.py), [`scripts/classify_monty_classes.py`](../scripts/classify_monty_classes.py) | behind [`scripts/sync_monty_libraries.sh`](../scripts/sync_monty_libraries.sh) and `mix monty.port_census` | `torch` for the export; plain `ast` for the census |

None of this runs during a test unless the test asks for it. The boundary tests
start [`test/support/probe_world.py`](../test/support/probe_world.py) with the
`python3` on your PATH — it answers from what it was sent, so it needs no numpy,
no Monty and no simulator — and the rest of the suite is green with
`MONTY_SOURCE=/nonexistent` and no Monty installed anywhere. Stepping Monty's own
world is the one thing that cannot be faked, and the setup page says so when the
peer is not available.

## Monty's configs, in the repository

What the application reads from Monty — its config tree,
[`priv/monty/conf`](../priv/monty/conf), and the snapshots the composer is held
to, [`priv/monty/snapshots`](../priv/monty/snapshots) — is checked in verbatim, so
**no Monty checkout is needed** to compile, test or run this. Monty's
[`LICENSE`](../priv/monty/LICENSE) travels with them, copied by the same task.

Refreshing the copy does need one:

```bash
export MONTY_SOURCE=../monty-orig   # the default: monty-orig next to the project
mix monty.inputs                    # fast-forward it, then copy conf + snapshots + LICENSE
mix monty.inputs --check            # is the copy what that checkout would give?
```

The revision it was copied from is in
[`priv/monty/inputs.json`](../priv/monty/inputs.json), and
[`priv/monty/README.md`](../priv/monty/README.md) says what is in the copy, what
deliberately is not, and whose licence it is under.

A checkout is needed to regenerate too: `mix monty.module_map.gen` reads the
Python of both packages (`MONTY_SOURCE`, `TELEOP_SOURCE`, default `../monty-orig`
and `../tbp.teleop`), and `mix monty.port_census` reads it as well.

## Invariants

* **Module for module.** Python `path/file.py::Class` becomes
  `Monty.Path.File.Class`, with a repeated segment collapsed and the class
  dropped when it repeats the file.
  [`lib/monty/module_map/data.ex`](../lib/monty/module_map/data.ex) records the
  mapping and `mix monty.module_map.verify` fails when a Monty file has no
  entry or an `implemented` entry has no module. Do not "improve" a name to
  fit Elixir style; recognisability is the point.
* **Functional core, actor shell.** Ported algorithms are pure functions over
  plain data, one-to-one with Python, tested directly. `Monty.Runtime.*` owns
  processes, routing and telemetry, and contains no algorithm. A GenServer
  callback that computes is a bug. Two exceptions are named rather than
  tolerated: a draw from the episode's stream, and a world, which holds a port.
* **Processes have a typed client API.** Call sites use
  `SensorModuleServer.step(server, ...)` or
  `LearningModuleServer.send_out_vote(server)`, never raw `GenServer.call/3`.
  The client functions and the callbacks are separate sections of the module,
  and every entry point carries a typespec.
* **Configs are read, never invented.** The Hydra subset implemented in
  `Monty.Config` is exactly what Monty's tree uses. Adding a resolver or a
  default means finding the corresponding use in Monty's `conf/`, not
  guessing.
* **The snapshots are the oracle.** `tests/conf/snapshots/*.yaml` in a Monty
  checkout is what Hydra composed. `mix monty.config.snapshots` compares path
  by path; a missing key is as much a difference as a wrong value.
* **Interpolations never survive into runtime.** Composition keeps `${...}`
  (as Monty's snapshots do); `Monty.Config.Resolvers` resolves them and reports
  unknown references instead of passing a `${...}` string along.
* **One RNG stream per episode.** Determinism is a feature: `Monty.Random.Stream`
  is the episode's one NumPy stream, a child of the model, and a module draws
  from it through `Monty.Context.rng` in the order it is stepped. That is why
  sensor modules are stepped one at a time. `Monty.Context.rng_for/2` derives a
  stream per module per step for the sites not yet moved onto the stream (noise
  transforms, a camera's message noise); it is a different set of numbers by
  construction, and [`monty-bugs.md`](monty-bugs.md) §2.1 lists what is left.
* **CMP payloads are validated at construction.** `Message.new/1` and
  `Goal.new/1` return `{:ok, struct} | {:error, reason}`; a process building a
  bad message gets an error, not a crash.
* **Config is read at boot** (`config/*.exs`); the dev reloader does not
  reload it.

## Tests

| Level | Where | Question |
| --- | --- | --- |
| Unit | [`test/monty/`](../test/monty) | what does a pure module decide? |
| Parity | `test/monty/**/*_parity_test.exs` | are these Monty's numbers? |
| Config | [`test/monty/config/`](../test/monty/config) | does Monty's config mean the same here? |
| Contract | [`test/monty/module_map_test.exs`](../test/monty/module_map_test.exs) | is the port still module for module? |
| Tasks | [`test/mix/`](../test/mix) | what does a Mix task do when a checkout is missing, stale or dirty? |
| Application | [`test/ex_tbp_monty/`](../test/ex_tbp_monty) | the non-web parts of the app: MCP, prerequisites, release plumbing |
| Component / web | [`test/ex_tbp_monty_web/`](../test/ex_tbp_monty_web) | what does a page or component render? |

Conventions: `start_supervised!/1` for processes, `Process.monitor/1` or
`_ = :sys.get_state/1` instead of `Process.sleep/1`, assertions about
behaviour rather than implementation, one reason to fail per test.

```bash
mix test                                  # everything
mix test test/monty/config                # the config contract
mix test --failed                         # what failed last time
```

## Gates

```bash
scripts/quality.sh            # lint, cover, CRAP (what CI runs)
scripts/quality.sh --fast     # lint only
mix lint                      # warnings-as-errors, unused deps, format, credo --strict, sobelow
mix cover                     # coverage threshold 85
mix complexity                # CRAP <= 20 (lib/monty, lib/ex_tbp_monty), <= 30 (web)
mix dialyzer                  # separate CI job; PLT cached
```

Sobelow's findings are reviewed where they are raised, not in a list. A call that
is not a traversal — a path this application built from a name it checked, a file
of its own — carries `# sobelow_skip ["Traversal.FileModule"]` immediately above
the function, with the reason on the line above *that*. There is no
`.sobelow-skips`: a file that says "we ignore directory traversal, XSS and code
execution" is a file nobody reviews, and it hides which of the findings were
looked at.

Two things about the annotation: it applies to the whole function it precedes, so
put it above a `def` and not inside one; and the reason must not continue on the
annotation's line — Sobelow rewrites that comment into an attribute, and trailing
prose turns the rewrite into a syntax error, which silently stops the file from
being scanned.

## Releases and images

CI publishes an image per ref to `ghcr.io/d-led/ex.tbp.monty`: `:main` and
`:latest` for a push to main, `:<branch>` for any other branch, `:v1.2.3` for a
release tag. The tag is the ref name, lower-cased, with anything but
`[a-z0-9._-]` turned into a dash. There are no commit-hash tags to wade
through: the commit is inside the image — `mix build.info` burns it into
`priv/build_info.json` — and the footer of every page shows it, with the pipeline
run that produced it linked beside it.

A branch publishes amd64 only. arm64 is compiled under QEMU and is most of the
job, so it is what a release tag — or `gh workflow run ci --ref main --field
image=true` — pays for, and only then does the tag carry both architectures.

The publishing job waits for lint, test and types, scans the result with Trivy,
and starts it as uid 10001 before pushing. The scan fails on any *fixable* HIGH
or CRITICAL finding; a finding this repository cannot fix — one vendored inside a
third-party wheel, say — is written down in
[`.trivyignore.yaml`](../.trivyignore.yaml) with the reason and the date the
exception expires, so it comes back to be argued rather than silently forgiven. The same two questions about a tag
you are about to make are answered at home:

```bash
docker build .             # does it build at all
scripts/quality.sh --image # builds it, checks the uid it runs as
```

## What a run costs

Measured on a warm cache (run `41189216324`, before the suite was split): a push
took **8 m 30 s**, and `mix cover` inside the `test` job was **7 m 49 s** of it.
`lint` and `types` finished in **25 seconds each** — the deps and `_build`
caches carry the compile, so they are formatting, credo, sobelow and dialyzer
over already-built beams. The suite is therefore the only thing worth splitting,
and anything else is noise by comparison.

It is split four ways. `mix test --partitions 4` hands each runner a slice of
the test *files*, which asks nothing of the tests themselves — no tags to
maintain, no list to keep in step. A partition sees a quarter of the lines the
suite can reach, so it runs with the threshold off (`COVERAGE_THRESHOLD=0`) and
exports what it covered; the `report` job merges the four exports, holds the
**total** to the 85% in [`mix.exs`](../mix.exs) (`mix test.coverage`), and hands
that same total to the CRAP ranking (`mix cover.merge` writes the one file
`mix crap` reads). The parity oracles run there too, once, because a total of
four quarters is not one of the quarters.

Each partition also publishes what it ran: when `CI` is set, `test/test_helper.exs`
adds `JUnitFormatter` and `mix test` writes `junit/junit-<partition>.xml`, which
`dorny/test-reporter` turns into a **check run** named `test <n>/4` — the failing
tests named, their lines annotated, and a count of what the quarter ran. The raw
XML is kept as an artifact beside the coverage export, so a check and its file can
be compared when they disagree. Nothing is written when `CI` is unset, because a
local run leaves no file for anybody to read.

The same three steps run at home:

```bash
for p in 1 2 3 4; do
  MIX_TEST_PARTITION=$p COVERAGE_THRESHOLD=0 mix test --partitions 4 --cover
done
mix test.coverage                  # the merged total, held to the threshold
mix cover.merge && mix complexity  # the same total, ranked
```

Two things are skipped on purpose, because they were pure cost:

* a push that only changes prose (`**/*.md`, `LICENSE`) — nothing it touches is
  compiled or shipped;
* a pull request from a branch in this repository, whose push run has already
  checked it and is what the pull request shows. A fork has no push run here,
  so a fork's PR is checked through the PR.

A run superseded by the next push is cancelled (`cancel-in-progress`), which
loses its minutes but not the answer: the newer run is the one that counts.

## Adding a module

1. Find the Python file and class in
   [`lib/monty/module_map/data.ex`](../lib/monty/module_map/data.ex).
2. Create the Elixir module at the mapped name.
3. Port the algorithm as pure functions; keep Python's names for structs and
   keys where they carry meaning (`pose_vectors`, `pose_fully_defined`).
4. Test behaviour first, against a Monty fixture where numbers are involved.
5. `mix monty.module_map.gen` to flip the entry to `implemented`, then
   `mix monty.module_map.verify` and [`scripts/quality.sh`](../scripts/quality.sh).

If a module genuinely cannot exist here (Hydra's own tooling), mark it
`excluded` with a reason in the generated file; the verifier requires one.
