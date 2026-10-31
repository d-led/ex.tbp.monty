# Developing Monty on the BEAM

Working on the code: invariants, the module contract, tests and gates.
Deployment and operations live in the Dockerfile and `rel/`.

## Local setup

```bash
docker compose up -d     # Postgres on :6432
mix setup
mix phx.server
```

Tests need the same database; `mix test` creates and migrates it. Config tests
need a Monty checkout (`MONTY_SOURCE`, default `../monty-orig`), and the module
contract needs both checkouts (`MONTY_SOURCE` and `TELEOP_SOURCE`, default
`../tbp.teleop`); without one they fail rather than pass quietly.

## Invariants

* **Module for module.** Python `path/file.py::Class` becomes
  `Monty.Path.File.Class`, with a repeated segment collapsed and the class
  dropped when it repeats the file. `lib/monty/module_map/data.ex` records the
  mapping and `mix monty.module_map.verify` fails when a Monty file has no
  entry or an `implemented` entry has no module. Do not "improve" a name to
  fit Elixir style; recognisability is the point.
* **Functional core, actor shell.** Ported algorithms are pure functions over
  plain data, one-to-one with Python, tested directly. `Monty.Runtime.*` owns
  processes, routing and telemetry, and contains no algorithm. A GenServer
  callback that computes is a bug.
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
* **One RNG stream per episode.** Determinism is a feature: the coordinator
  threads the random state in Python's order. Parallel-friendly per-module
  streams are a future mode, not the default.
* **CMP payloads are validated at construction.** `Message.new/1` and
  `Goal.new/1` return `{:ok, struct} | {:error, reason}`; a process building a
  bad message gets an error, not a crash.
* **Config is read at boot** (`config/*.exs`); the dev reloader does not
  reload it.

## Tests

| Level | Where | Question |
| --- | --- | --- |
| Unit | `test/monty/**` | what does a pure module decide? |
| Parity | `test/monty/config/**` | does Monty's config mean the same here? |
| Contract | `test/monty/module_map_test.exs` | is the port still module for module? |
| Component / web | `test/ex_tbp_monty_web/**` | what does a page or component render? |

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
`priv/build_info.json` — and the footer of every page shows it, with the
pipeline run that produced it linked beside it.

A branch publishes amd64 only. arm64 is compiled under QEMU and is most of the
job, so it is what a release tag — or `gh workflow run ci --ref main --field
image=true` — pays for, and only then does the tag carry both architectures.

The publishing job waits for lint, test and types, scans the result with Trivy,
and starts it as uid 10001 before pushing. The same two questions about a tag
you are about to make are answered at home:

```bash
docker build .             # does it build at all
scripts/quality.sh --image # builds it, checks the uid it runs as
```

## What a run costs

Measured on a warm cache (run `41189216324`): a push takes **8 m 30 s**, and
`mix cover` inside the `test` job is **7 m 49 s** of it. `lint` and `types`
finish in **25 seconds each** — the deps and `_build` caches carry the compile,
so they are formatting, credo, sobelow and dialyzer over already-built beams.
The suite is therefore the only thing worth optimising; anything else is noise
by comparison.

Two things are skipped on purpose, because they were pure cost:

* a push that only changes prose (`**/*.md`, `LICENSE`) — nothing it touches is
  compiled or shipped;
* a pull request from a branch in this repository, whose push run has already
  checked it and is what the pull request shows. A fork has no push run here,
  so a fork's PR is checked through the PR.

A run superseded by the next push is cancelled (`cancel-in-progress`), which
loses its minutes but not the answer: the newer run is the one that counts.

## Adding a module

1. Find the Python file and class in `lib/monty/module_map/data.ex`.
2. Create the Elixir module at the mapped name.
3. Port the algorithm as pure functions; keep Python's names for structs and
   keys where they carry meaning (`pose_vectors`, `pose_fully_defined`).
4. Test behaviour first, against a Monty fixture where numbers are involved.
5. `mix monty.module_map.gen` to flip the entry to `implemented`, then
   `mix monty.module_map.verify` and `scripts/quality.sh`.

If a module genuinely cannot exist here (Hydra's own tooling), mark it
`excluded` with a reason in the generated file; the verifier requires one.
