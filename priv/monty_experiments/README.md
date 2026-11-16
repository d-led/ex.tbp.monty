# Our experiments

The experiments in this tree are **this application's**, not Monty's. They are
read through the `:conf_dir` option every opener already takes
(`Monty.Studio.open/2`, `Monty.Studio.Catalog.experiments/1`,
`Monty.Studio.Readiness`), under the path
`ExTbpMonty.AnimalExperiments.conf_dir/0` → `priv/monty_experiments/conf`.

## Why not `priv/monty/conf`

`mix monty.inputs` (and so `mix monty.refresh`) mirrors Monty's config tree into
`priv/monty` and **deletes any other YAML under `conf/` or `snapshots/`** —
`Monty.Config.Inputs.sync/2`, whose `prune/3` is the deleting part. A config
written there survives until the next refresh and then vanishes without a
message. That is the whole reason this directory exists.

`test/ex_tbp_monty/animal_experiments_test.exs` holds the rule.

## What goes here

Only the files that differ from Monty's copy — an environment group naming a new
object set's `data_path`, and the experiments that use it. Everything else is
Monty's, and stays in the mirror where a refresh keeps it current.

What those experiments are for, and the corpora they need, is a plan rather than
a property of this tree: it lives in MemPalace (wing `ex.tbp.monty`, room `plan`)
and in the agent memory `animal-corpus.md`.
