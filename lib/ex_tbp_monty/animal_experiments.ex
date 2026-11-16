defmodule ExTbpMonty.AnimalExperiments do
  @moduledoc """
  Where this application keeps the experiments that are not Monty's own.

  `mix monty.inputs` **mirrors** Monty's config tree: it writes
  `conf/**/*.yaml` and `snapshots/**/*.yaml` into `priv/monty` and deletes every
  other YAML under those two prefixes (`Monty.Config.Inputs.sync/2`). A config
  written under `priv/monty/conf/` is therefore deleted by the next refresh.

  Ours live in a tree of the same Hydra shape beside it, and every opener that
  already takes `:conf_dir` can read it — `Monty.Studio.open/2`,
  `Monty.Studio.Catalog.experiments/1`, `Monty.Studio.Readiness`. This module is
  the one place that names the path, so a test can hold the rule that it is
  outside the mirror.

  The corpus those experiments need is data, not configuration: it lands under
  `MONTY_DATA` through `/prerequisites` like every other object set, and never
  in this repository. `docs/animal-experiments.md` is the plan.
  """

  @doc """
  The Hydra config tree for this application's own experiments.

  It may be empty: a tree with no experiment in it composes nothing, and the
  point of the name is that it is the tree the next config is written into.
  """
  @spec conf_dir() :: Path.t()
  def conf_dir, do: Path.join(:code.priv_dir(:ex_tbp_monty), "monty_experiments/conf")
end
