# What comes from Monty

Everything this repository takes from the Thousand Brains Project's Monty, in one
table: what it is, where it lands, the glob it arrives as, and the one command
that writes it. Nothing here is edited by hand, so the last column is how a
reader checks a row instead of trusting this page.

| What                                                                                  | Lands in                                                                                                                  | Arrives as                             | Written by                                                                           | Checked by                        |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------- |
| Monty's Hydra config tree — every experiment, group and module a config can name      | [`priv/monty/conf`](../priv/monty/conf)                                                                                   | `**/*.yaml` of `src/tbp/monty/conf/`   | `mix monty.inputs`                                                                   | `mix monty.inputs --check`        |
| the trees Hydra composed for Monty's snapshot tests — the composer's oracle           | [`priv/monty/snapshots`](../priv/monty/snapshots)                                                                         | `**/*.yaml` of `tests/conf/snapshots/` | `mix monty.inputs`                                                                   | `mix monty.inputs --check`        |
| Monty's licence, for the two above                                                    | [`priv/monty/LICENSE`](../priv/monty/LICENSE)                                                                             | one file                               | `mix monty.inputs`                                                                   | `mix monty.inputs --check`        |
| which commit the copy is, and how many files it holds                                 | [`priv/monty/inputs.json`](../priv/monty/inputs.json)                                                                     | one file                               | `mix monty.inputs`                                                                   | the file itself                   |
| Monty's pretrained memories, in a format this port reads                              | [`priv/monty/libraries`](../priv/monty/libraries)                                                                         | `<release>/<model>.jsonl.gz`           | `mix monty.prerequisites.fetch`                                                      | `git status priv/monty/libraries` |
| what each Python class _is_, and which classes Monty's configs name                   | [`priv/monty/port_census.json`](../priv/monty/port_census.json), [`target_census.json`](../priv/monty/target_census.json) | one file each                          | `mix monty.port_census --json`, `mix monty.target_census --json`                     | run them again with `--json`      |
| what Monty _answered_, so the parity tests replay it rather than recompute it         | [`test/fixtures/monty_*`](../test/fixtures)                                                                               | `*.json`, `*.jsonl`                    | [`scripts/record_monty_*.py`](../scripts) (needs a `$MONTY_PYTHON` with Monty in it) | `git diff test/fixtures`          |
| the module contract — Monty's file to Elixir module, **generated** rather than copied | [`lib/monty/module_map/data.ex`](../lib/monty/module_map/data.ex)                                                         | one generated module                   | `mix monty.module_map.gen`                                                           | `mix monty.module_map.verify`     |
| the world — MuJoCo, in this repository's own Python, mirroring Monty's simulator      |

        | [`priv/monty_py/world.py`](../priv/monty_py/world.py)
                                                    | one file
             | written here, against `mujoco`, `numpy` and `numpy-quaternion`; run by `pythonx` inside the release
                                                                      | `mix test`, and a run that steps MuJoCo |

Three kinds, and the distinction is the one to keep:

- **copied** — verbatim bytes, diffable against a checkout: `conf/`, `snapshots/`,
  `LICENSE`. Only `*.yaml` travels out of Monty's `conf/`: the Python that runs
  Hydra (`update_snapshots.py`, `compare_snapshots.py`) and a working tree's
  `__pycache__` are neither read nor copied. A file upstream deleted is deleted
  here too, because a config that no longer exists must not linger in the studio.
- **generated** — a map or a classification _of_ Monty, written from a checkout by
  a task: `data.ex` and the two census files. Re-running the task is the review.
- **written here** — the world: MuJoCo's scene, its agents and its cameras, in
  `priv/monty_py/world.py`. It mirrors Monty's `simulators/mujoco/` rather than
  being copied, because the copy answered in Monty's Python classes and went
  stale with them. It travels with this repository and runs in the interpreter
  the release carries, so nothing has to be installed to step a scene.

## What deliberately does not travel

Monty's Python source — that is the thing being ported, and
[`data.ex`](../lib/monty/module_map/data.ex) says where each file went. Its
`tests/` and its `docs/`: the MCP server reads the documentation out of a
checkout at request time, when somebody has one. Its `environment.yml` and
`pyproject.toml`, because this project does not run Monty's environment. The
published archives (object meshes, model bundles) that an experiment downloads:
those are not inputs to the port but to a run, and they live in
[`priv/prerequisites.yaml`](../priv/prerequisites.yaml) — see
[`container.md`](container.md).

## Where this is repeated

Nowhere. Each of these pages says only what its own subject needs and links back
here rather than restating the table:

- [`architecture.md`](architecture.md#what-comes-from-monty) — the shape of a
  timestep, and why the boundary falls where it does.
- [`priv/monty/README.md`](../priv/monty/README.md) — that directory's own change
  process, and whose licence it is under.
- [`THIRD-PARTY.md`](../THIRD-PARTY.md) — the licences, for this and for
  everything else this project ships that it did not write.
