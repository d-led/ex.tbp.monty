defmodule Monty.Experiment.MatchCriteria do
  @moduledoc """
  Turning per-module terminal states into one system-level decision.

  Mirrors `tbp/monty/experiment/match_criteria.py`. A learning module concludes
  on its own — it recognised an object, it gave up, or it ran out of time — and
  something has to decide what the *system* believes. That is a criterion: a
  function of the terminal states of all modules.

    * `Monty.Experiment.MatchCriteria.AnyLMsMatch` — enough modules matched;
    * `Monty.Experiment.MatchCriteria.NamedLMsMatch` — these modules matched.

  A criterion is carried as `{module, argument}`, the same way this port carries
  a hypotheses updater: the module answers and the argument is the
  configuration, so an experiment picks a criterion without the coordinator
  knowing which one it got.
  """
end
