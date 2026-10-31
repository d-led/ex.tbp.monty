# Features

What this repository does, checked in the tree on 2026-10-31. Every claim links to
the thing that proves it. Anything not built is listed at the end, so nobody has to
guess. The counts are measured by [`scripts/refresh_features.py`](../scripts/refresh_features.py),
not recalled — run it after anything lands that can move one.

## Port

- **One naming rule, no translation table.** `path/file.py::Class` →
  `Monty.Path.File.Class`; a repeated segment collapses, a class repeating the file
  name is dropped. ([rule](module-map.md))
- **The map is the contract.** 131 Python files (124 `tbp.monty`, 7 `tbp.teleop`),
  355 classes. Implemented: 48 files / 173 classes. Planned: 79 / 180. Excluded: 4 / 2.
  ([`module_map/data.ex`](../lib/monty/module_map/data.ex))
- `mix monty.module_map.gen` re-derives the map from the checkouts;
  `mix monty.module_map.verify` fails on an unmapped file, an `implemented` entry
  with no module, or an exclusion with no reason.
- **Monty's Hydra YAML is read unchanged**, with a documented subset of Hydra
  features. ([config-compatibility.md](config-compatibility.md))
- **Snapshot gate:** composes each experiment Monty commits a snapshot for
  (54 files at `monty@760ad174`) and diffs it path by path — an extra key is a
  failure too. ([`snapshot_check.ex`](../lib/monty/config/snapshot_check.ex))
- **Numbers checked against Monty**, strongest first: replayed (Monty's own code ran
  and its answers are committed fixtures), recorded (whole episodes), counted
  (config and naming). Each check names its tolerance and its test.
  ([validation.md](validation.md), 10 `*_parity_test.exs` files)
- **Deliberate differences are written down**, so a Python/Elixir diff is
  explainable. ([monty-bugs.md](monty-bugs.md))
- Deterministic: one RNG value threaded through Python's call order.
  ([architecture.md](architecture.md))

## Runtime

- Sensor modules, learning modules and the motor system are BEAM processes; the step
  coordinator fans out and gathers per phase (`Monty.Runtime.Barrier`), in Monty's
  order. ([architecture.md](architecture.md))
- Voting is `:gen_server.multi_call`: `:infinity` reproduces Python's synchronous
  round, a finite deadline closes the round and reports `inputs_used` /
  `deadline_hit?` as telemetry.
- One process per module under `:one_for_one`: a crashed module restarts and the step
  count survives.
- Runs are Oban jobs recorded in Postgres (`studio_runs`), so a run outlives the HTTP
  request. ([`jobs_live.ex`](../lib/ex_tbp_monty_web/live/jobs_live.ex))

## Worlds

- **Synthetic world in the BEAM:** sphere scene, pinhole camera answering depth,
  rgba and semantic images, MuJoCo-convention kinematics; the sensor's curvature
  estimate is checked against the sphere's closed form. ([simulator-port.md](simulator-port.md))
- **Monty's real world through a Python peer:**
  `Monty.Simulators.Habitat.Environment.HabitatEnvironment` is `implemented` in the
  map and runs [`scripts/monty_simulator_peer.py`](../scripts/monty_simulator_peer.py);
  `MONTY_WORLD=monty|habitat|synthetic` picks the world at boot.
  ([`runtime.exs`](../config/runtime.exs))
- **Port contract:** 4-byte big-endian length + UTF-8 JSON, one request in flight, a
  timeout is an error, actions in Monty's own JSON shape.
  ([`port/protocol.ex`](../lib/monty/simulators/port/protocol.ex))
- **Recorded percepts replay through the real runtime:**
  `Monty.Simulators.Recording.SensorModule`.
  ([`recording/sensor_module.ex`](../lib/monty/simulators/recording/sensor_module.ex))

## Studio (Phoenix LiveView)

- `/` — every experiment, faceted by agent, module count, learning module and start
  point; the filters live in the URL.
- `/experiments/*name` — wiring diagram, findings, the composed config, and a run that
  streams as it steps.
- `/build` — an experiment from a blueprint, previewed by composing the config it
  would write; drafts saved to `priv/experiments`.
- `/runs`, `/runs/:id` — history and replay: per-step sensor frames, the object
  centred with the agent in frame, an evidence chart, hypothesis counts, and why the
  run stopped. Run files (`/runs/:id/files/:name`) are served as they are.
- `/jobs` — the Oban queue, with cancel (ends at the next step) and kill.
- `/prerequisites` — data and pretrained models downloaded into Monty's own
  `MONTY_DATA` / `MONTY_MODELS` paths: streamed, written to `<target>.part`, renamed
  only when the checksum matches — 2 entries in
  [`priv/prerequisites.yaml`](../priv/prerequisites.yaml).
- `/health` answers 200 and nothing else; a CSP header is set for the browser scope;
  there is no authentication. ([`router.ex`](../lib/ex_tbp_monty_web/router.ex))

## CLI

```bash
mix monty.run <experiment> [--steps N] [--seed N] [--record|--no-record] [--quiet] [--pretrained-dir DIR]
mix monty.bench <experiments...> [--steps N] [--repeat N] [--json]   # this port's loop, no DB
mix monty.config.snapshots     # parity with Monty's composed configs
mix monty.module_map.gen       # regenerate the map
mix monty.module_map.verify    # coverage of the map
mix monty.port_census          # what is left to port, from Monty's AST
mix monty.target_census        # which classes the configs instantiate
mix build.info                 # commit + build metadata into the release
```

`mix monty.run` records by default (the run shows up in `/runs`) and exits 1 when the
config would not start, so CI can use it. `mix lint`, `mix cover`, `mix complexity`,
`mix dialyzer`; `mix precommit` is `scripts/quality.sh`, what CI runs.

## MCP server

- `POST /mcp`: JSON-RPC 2.0 over Streamable HTTP, stateless — no session header, no
  SSE (`GET`/`DELETE` → 405), no batches. ([mcp.md](mcp.md))
- **17 tools**, all `monty_*`: docs search/read/index, roadmap list/task, module
  lookup/port status/code-in-doc, experiment options/describe/list/preview/create/run/
  report/list-runs.
- Answers come from the sources, not a copy: the checkout's `docs/`, its `future-work`
  front matter, the generated module map, `Monty.Studio` and `studio_runs`. Doc answers
  carry the page's published URL; port status is the map's verdict.
- Creating is preview-first, and a run is queued as the studio's own Oban job. `Origin`
  and `MCP-Protocol-Version` are checked; no auth.

## Logging, including wandb

- Monty's `logging` group resolves through the module map; a class not ported is named
  and skipped rather than silently replaced.
  ([`studio/logging.ex`](../lib/monty/studio/logging.ex))
- CSV stats, detailed JSON, graph-matching and exp loggers are here.
  ([loggers](../lib/monty/frameworks/loggers))
- **wandb: offline and online, one code path.** Runs call the real `wandb` client from
  an embedded CPython the app owns (`pythonx`, `requires-python ==3.13.*`,
  `wandb==0.19.1` — [`config/pythonx.exs`](../config/pythonx.exs)). `WANDB_MODE` and
  `WANDB_DIR` are forwarded from the BEAM environment on every `init`, so a run is
  offline to a local `run-*.wandb` or online to the service without this code knowing
  which. Offline is asserted in
  [`pythonx_client_test.exs`](../test/monty/frameworks/loggers/wandb_handlers/pythonx_client_test.exs).
- `WandbWrapper` and `WandbHandler` are `implemented`; the five table/chart/marked-obs
  handlers are not.

## Ops and distribution

- **Docker image at `ghcr.io/d-led/ex.tbp.monty`:** `:main` + `:latest`, `:<branch>`
  for any branch, `:v1.2.3` for a release tag (amd64 **and** arm64; branches are amd64).
  No commit-hash tags — the commit is in `priv/build_info.json` and the page footer.
- Trivy (CRITICAL/HIGH, fixable only) runs before the push, and CI asserts the image
  runs as uid 10001. `/app/bin/migrate` once, then `/app/bin/server`.
  ([`Dockerfile`](../Dockerfile))
- CI: `lint` → `test` ×4 partitions (Postgres 17 service) → `report` (merged coverage
  ≥ 85, CRAP ranking, both parity oracles) → `types` → `image`. Prose-only pushes are
  skipped. Elixir 1.20.4 / OTP 29.1.2.
  ([`ci.yml`](../.github/workflows/ci.yml))
- Stack: Phoenix 1.8, LiveView 1.2, Ecto/Postgres, Oban 2.20, Bandit, Req, Tailwind 4
  + daisyUI 5 + heroicons, `yaml_elixir` for Hydra YAML, `pythonx` for Python.
  ([`mix.exs`](../mix.exs))
- `docker compose up -d` gives Postgres 17 and adminer. ([compose](../docker-compose.yml))
- 1,683 `test` declarations in the suite.

## Not built — do not assume these

- MuJoCo: no Elixir-side world; its map entries are `planned`. Upstream also deleted
  its MuJoCo experiment presets.
- wandb: the five stats handlers and `mark_obs` frame marking.
- Parallel episodes and stepping a live world: designed, not built.
  ([parallel-and-live.md](parallel-and-live.md))
- `tbp.teleop`: 0 of its 7 mapped modules exist (no `lib/teleop/`).
- `MontyObjectRecognitionExperiment`: upstream's body calls a hook that is `pass`, so
  it is left planned on purpose.
