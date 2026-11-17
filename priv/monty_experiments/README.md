# Our experiments

The configs in this tree are **this application's**, not Monty's. They are kept
here, beside Monty's mirror, and composed as an overlay over it.

## The shape

```
priv/monty_experiments/
  sets/<name>/conf/     one experiment set: its own experiments, its own
                        overrides of Monty's groups, its own termination budgets
  conf/                 group files that every set inherits
```

`Monty.Config.Source.conf_dirs/0` answers the roots in the order that
decides who wins:

```
sets/*/conf  (sorted)  ->  conf  ->  priv/monty/conf
```

`Monty.Config.Source.load/3` reads that list as an overlay — the first root that
holds a file wins — and `Source.experiments/1` unions the experiment names
across roots. So a set beats the shared tree, which beats Monty: a set can
replace a group file for its own experiments without touching anything shared,
and the shared tree can replace a Monty group once for everybody.

**Adding a set is `mkdir` plus YAML.** Nothing enumerates sets by name; the tree
is the registry, and the studio lists what it finds.

## Why not `priv/monty/conf`

`mix monty.inputs` (and so `mix monty.refresh`) mirrors Monty's config tree into
`priv/monty` and **deletes any other YAML under `conf/` or `snapshots/`** —
`Monty.Config.Inputs.sync/2`, whose `prune/3` is the deleting part. A config
written there survives until the next refresh and then vanishes without a
message. Everything here is a sibling of that mirror, never inside it.

`test/monty/config/source_conf_dirs_test.exs` holds both halves: every root is
outside the mirror, and a refresh leaves our files alone.

## What goes in a set

Only what differs from Monty's copy — an environment group naming the object
set's `data_path`, the env interfaces that place objects from it, and the
experiments that use them. Everything else is Monty's and stays in the mirror,
where a refresh keeps it current.

What the experiments are for, and the corpora they need, is a plan rather than a
property of this tree: it lives in MemPalace (wing `ex.tbp.monty`, room `plan`)
and in the agent memory `animal-corpus.md`.

## Running one

```
mix monty.run dogs/surf_unsupervised --world ex_mujoco
mix run --no-start scripts/probe_recognitions.exs dogs/inference_paired 8
```

The runner and the studio both default to `conf_dirs/0`, so a name in a set runs
without an `--overlay`. An overlay is still accepted for a tree that is not part
of this application, and is read before the sets.
