# Monty's own inputs, copied here verbatim

This directory holds what this application **reads** from the Thousand Brains
Project's Monty, checked in so that building the image, running the test suite
and running CI need no Monty checkout: the config tree, the snapshots it was
composed into, the licence for both, and the pretrained memories exported in a
format this port can read.

The list of everything that comes from Monty — every path, glob, writer and the
command that checks it — is [`docs/from-monty.md`](../../docs/from-monty.md).
This page covers only what is different about *this* directory: how it changes,
and whose work it is.

## How it changes

Nothing here is edited by hand. The YAML and the licence are produced by

    mix monty.inputs                 # from $MONTY_SOURCE, else ../monty-orig

which copies `*.yaml` from the two directories Monty keeps them in plus
`LICENSE`, deletes what upstream deleted, and rewrites `inputs.json`. A
`git diff priv/monty` after running it is the whole review of an upstream pull.
`mix monty.inputs --check` answers whether the copy is what a checkout would
give, and writes nothing.

The memories change only when
[`scripts/sync_monty_libraries.sh`](../../scripts/sync_monty_libraries.sh) is run
(it needs `torch`, so it needs Monty's Python), and the two census files only
when their tasks are asked to write them.

Only `*.yaml` travels, plus the licence. Monty's `conf/` also holds the Python
that runs Hydra (`update_snapshots.py`, `compare_snapshots.py`) and the
`__pycache__` of a working tree; this application reads none of it. Monty's
Python source, its `tests/` and its `docs/` are deliberately absent — see
[what deliberately does not travel](../../docs/from-monty.md#what-deliberately-does-not-travel).

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
