# What comes from Monty

Everything this repository takes from the Thousand Brains Project's Monty, in one
table: what it is, where it lands, the glob it arrives as, and the one command
that writes it. Nothing here is edited by hand, so the last column is how a
reader checks a row instead of trusting this page.

| What                                                                                  | Lands in                                                                                                                  | Arrives as                             | Written by                                                                           | Checked by                               |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------- |
| Monty's Hydra config tree — every experiment, group and module a config can name      | [`priv/monty/conf`](../priv/monty/conf)                                                                                   | `**/*.yaml` of `src/tbp/monty/conf/`   | `mix monty.inputs`                                                                   | `mix monty.inputs --check`               |
| the trees Hydra composed for Monty's snapshot tests — the composer's oracle           | [`priv/monty/snapshots`](../priv/monty/snapshots)                                                                         | `**/*.yaml` of `tests/conf/snapshots/` | `mix monty.inputs`                                                                   | `mix monty.inputs --check`               |
| Monty's licence, for the two above                                                    | [`priv/monty/LICENSE`](../priv/monty/LICENSE)                                                                             | one file                               | `mix monty.inputs`                                                                   | `mix monty.inputs --check`               |
| which commit the copy is, and how many files it holds                                 | [`priv/monty/inputs.json`](../priv/monty/inputs.json)                                                                     | one file                               | `mix monty.inputs`                                                                   | the file itself                          |
| Monty's pretrained memories, in a format this port reads                              | `<data>/libraries`                                                                                                        | `<release>/<model>.jsonl.gz`           | `mix monty.prerequisites.fetch`                                                      | its sha256, in `priv/prerequisites.yaml` |
| what each Python class _is_, and which classes Monty's configs name                   | [`priv/monty/port_census.json`](../priv/monty/port_census.json), [`target_census.json`](../priv/monty/target_census.json) | one file each                          | `mix monty.port_census --json`, `mix monty.target_census --json`                     | run them again with `--json`             |
| what Monty _answered_, so the parity tests replay it rather than recompute it         | [`test/fixtures/monty_*`](../test/fixtures)                                                                               | `*.json`, `*.jsonl`                    | [`scripts/record_monty_*.py`](../scripts) (needs a `$MONTY_PYTHON` with Monty in it) | `mix monty.data.check`                   |
| the module contract — Monty's file to Elixir module, **generated** rather than copied | [`lib/monty/module_map/data.ex`](../packages/ex_tbp_monty_core/lib/monty/module_map/data.ex)                              | one generated module                   | `mix monty.module_map.gen`                                                           | `mix monty.module_map.verify`            |
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

## A new Monty landed: one command

```
mix monty.refresh            # fast-forward the checkout, then everything below
mix monty.refresh --no-update  # copy the checkout exactly as it stands
```

The refresh has two halves, and both are needed. The first is the **copy** of
Monty's files. The second is the **map** from each Python class to the Elixir
module that answers for it, with the censuses that say which of those a config
names. Run in this order, each a task of its own:

1. `mix monty.inputs` — fast-forward, then copy `conf/`, the snapshots and the
   licence into `priv/monty/`;
2. `mix monty.module_map.gen` — rewrite
   `packages/ex_tbp_monty_core/lib/monty/module_map/data.ex`, recording the Monty
   commits it was read from;
3. `mix monty.target_census` — recompose every experiment and collect the
   `_target_`s into `priv/monty/target_census.json`;
4. `mix monty.config.snapshots` — compose every experiment and compare it with
   Monty's own snapshot;
5. `mix monty.module_map.verify` — coverage, `implemented` pointing at real
   modules, `planned` pointing at modules nobody has written yet, `excluded`
   saying why, no checkout past the map;
6. `mix monty.readiness` — the numbers, because they moved.

The chain stops at the first step that refuses, whose own message says what to
do. A census written after a failed copy would describe a tree the map
disagrees with, which is why they are one command and not six lines in a
README.

## What deliberately does not travel

Monty's Python source — that is the thing being ported, and
[`data.ex`](../packages/ex_tbp_monty_core/lib/monty/module_map/data.ex) says where each file went. Its
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

## The record each row is checked against

Every table row above is a data set with an origin, and one file states it:
[`priv/data_provenance.yaml`](../priv/data_provenance.yaml). Each entry says what
kind of thing it is, where it came from, on what terms, what writes it, and the
sha256 of the bytes. For a directory that is a tree hash, so four hundred configs
are one number that still moves when any file inside them does.

    mix monty.data.check

`mix monty.data.check` recomputes every hash and prints the four things that can
be wrong with the record: a data file no entry mentions, an entry whose bytes
changed, an entry with no sha256, an entry pointing at nothing.
`test/monty/data_provenance_test.exs` fails on the same four lists, so data
cannot arrive in a commit without its origin — and the fix a stale entry needs is
in the task's own output.

**No model is in this repository, and none may be.** A pretrained memory is what
Monty's training wrote. Exporting it is `mix monty.prerequisites.fetch`'s work; it
arrives through `/prerequisites`, and its record is the archive's sha256 in
`priv/prerequisites.yaml`, the same place and the same kind of statement as the
object meshes. A memory committed here would be a model nobody can
re-derive: true of one machine one day, with nothing in the tree to say how it
come to be. That is why none of it is in the tree: the export writes it under the
data folder, and the archive's checksum is the record of where it came from.
