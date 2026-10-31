# Monty's own inputs, copied here verbatim

This directory holds what this application **reads** from the Thousand Brains
Project's Monty, checked in so that building the image, running the test suite
and running CI need no Monty checkout.

| Path | What it is | Where it came from |
| --- | --- | --- |
| `conf/` | Monty's Hydra config tree (`*.yaml` only) — every experiment, group and module its configs can name | `src/tbp/monty/conf/` |
| `snapshots/` | the trees Hydra composed for the experiments Monty ships a snapshot for — the oracle our composer is checked against | `tests/conf/snapshots/`, including the tour's under `tutorial/` |
| `LICENSE` | Monty's MIT licence, for the files above | the checkout's `LICENSE` |
| `libraries/` | Monty's pretrained memories, exported to a format this port can read; see [`libraries/README.md`](libraries/README.md) | Monty's published prerequisites, by [`scripts/sync_monty_libraries.sh`](../../scripts/sync_monty_libraries.sh) |
| `port_census.json`, `target_census.json` | what each Python class is, and which classes Monty's configs name | `mix monty.port_census --json …`, `mix monty.target_census --json …` |
| `inputs.json` | the Monty commit the copy was taken from, and how many files it holds | `Monty.Config.Inputs`, when `mix monty.inputs` copies |

## How it changes

Nothing here is edited by hand. The YAML and the licence are produced by

    mix monty.inputs                 # from $MONTY_SOURCE, else ../monty-orig

which copies `*.yaml` from the two directories above plus `LICENSE`, deletes
what upstream deleted, and rewrites `inputs.json`. A `git diff priv/monty` after
running it is the whole review of an upstream pull. `mix monty.inputs --check`
answers whether the copy is what a checkout would give, and writes nothing.

The memories change only when
[`scripts/sync_monty_libraries.sh`](../../scripts/sync_monty_libraries.sh) is run
(it needs `torch`, so it needs Monty's Python), and the two census files only
when their tasks are asked to write them.

Only `*.yaml` travels, plus the licence. Monty's `conf/` also holds the Python
that runs Hydra (`update_snapshots.py`, `compare_snapshots.py`) and the
`__pycache__` of a working tree; this application reads none of it. Monty's
Python source, its `tests/` and its `docs/` are deliberately absent — the module
contract is generated into
[`lib/monty/module_map/data.ex`](../../lib/monty/module_map/data.ex) by
`mix monty.module_map.gen`, and the MCP server reads Monty's docs from a checkout
only when somebody has one.

## Licence and attribution

The files in `conf/` and `snapshots/` are Monty's, copied without modification,
under Monty's MIT licence:

    Copyright 2025 Thousand Brains Project
    Copyright 2021-2024 Numenta Inc.

The licence text travels with them as [`LICENSE`](LICENSE) in this directory
(copied by the same task, so it cannot drift from what it describes), and the
project's source is <https://github.com/thousandbrainsproject/tbp.monty>. The
commit this copy was taken from is in `inputs.json`.

The pretrained models in [`libraries/`](libraries) are published by the Thousand
Brains Project as part of Monty's prerequisites; [`libraries/README.md`](libraries/README.md)
records which archive each file came from and how it was exported.

See [`THIRD-PARTY.md`](../../THIRD-PARTY.md) at the root for everything else this
project ships that it did not write.
