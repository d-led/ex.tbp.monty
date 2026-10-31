# Monty's own inputs, copied here verbatim

This directory holds what this application **reads** from the Thousand Brains
Project's Monty, checked in so that building the image, running the test suite
and running CI need no Monty checkout.

| Path | What it is | Where it came from |
| --- | --- | --- |
| `conf/` | Monty's Hydra config tree (`*.yaml` only) — every experiment, group and module its configs can name | `src/tbp/monty/conf/` |
| `snapshots/` | the trees Hydra composed for the experiments Monty ships a snapshot for — the oracle our composer is checked against | `tests/conf/snapshots/` |
| `libraries/` | Monty's pretrained memories, exported to a format this port can read; see `libraries/README.md` | Monty's published prerequisites |
| `port_census.json`, `target_census.json` | what each Python class is, and which classes Monty's configs name | `mix monty.port_census`, `mix monty.target_census` |
| `inputs.json` | the Monty commit the copy was taken from, and how many files it holds | written by the sync script |

## How it changes

Nothing here is edited by hand. The copy is produced by

    mix monty.inputs                 # from $MONTY_SOURCE, else ../monty-orig

which copies `*.yaml` from the two directories above, deletes what upstream
deleted, and rewrites `inputs.json`. A `git diff priv/monty` after running it is
the whole review of an upstream pull.

Only `*.yaml` travels. Monty's `conf/` also holds the Python that runs Hydra
(`update_snapshots.py`, `compare_snapshots.py`) and the `__pycache__` of a
working tree; this application reads none of it. Monty's Python source, its
`tests/` and its `docs/` are deliberately absent — the module contract is
generated into `lib/monty/module_map/data.ex`, and the MCP server reads Monty's
docs from a checkout only when somebody has one.

## Licence and attribution

The files in `conf/` and `snapshots/` are Monty's, copied without modification,
under Monty's MIT licence:

    Copyright 2025 Thousand Brains Project
    Copyright 2021-2024 Numenta Inc.

The licence text travels with them as [`LICENSE`](LICENSE) in this directory
(copied by the same script, so it cannot drift from what it describes), and the
project's source is <https://github.com/thousandbrainsproject/tbp.monty>. The
commit this copy was taken from is in `inputs.json`.

The pretrained models in `libraries/` are published by the Thousand Brains
Project as part of Monty's prerequisites; `libraries/README.md` records which
archive each file came from and how it was exported.

See [`THIRD-PARTY.md`](../../THIRD-PARTY.md) at the root for everything else this
project ships that it did not write.
