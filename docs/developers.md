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
need a Monty checkout (`MONTY_SOURCE`, default `../monty-orig`); without one
they are skipped, not silently passed.

## Invariants

* **Module for module.** Python `path/file.py::Class` becomes
  `Monty.Path.File.Class`, with a repeated segment collapsed and the class
  dropped when it repeats the file. `priv/monty/module_map.exs` records the
  mapping and `mix monty.module_map.verify` fails when a Monty file has no
  entry or an `implemented` entry has no module. Do not "improve" a name to
  fit Elixir style; recognisability is the point.
* **Functional core, actor shell.** Ported algorithms are pure functions over
  plain data, one-to-one with Python, tested directly. `Monty.Runtime.*` owns
  processes, routing and telemetry, and contains no algorithm. A GenServer
  callback that computes is a bug.
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

Sobelow's reviewed findings live in `.sobelow-skips`; regenerate only after a
review (`mix sobelow --config --mark-skip-all`). Inline `# sobelow_skip`
comments are avoided because Sobelow's comment parser chokes on prose after
them.

## Adding a module

1. Find the Python file and class in `priv/monty/module_map.exs`.
2. Create the Elixir module at the mapped name.
3. Port the algorithm as pure functions; keep Python's names for structs and
   keys where they carry meaning (`pose_vectors`, `pose_fully_defined`).
4. Test behaviour first, against a Monty fixture where numbers are involved.
5. `mix monty.module_map.gen` to flip the entry to `implemented`, then
   `mix monty.module_map.verify` and `scripts/quality.sh`.

If a module genuinely cannot exist here (Hydra's own tooling), mark it
`excluded` with a reason in the generated file; the verifier requires one.
