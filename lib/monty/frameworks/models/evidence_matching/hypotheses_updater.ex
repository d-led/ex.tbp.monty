defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater do
  @moduledoc """
  How a learning module decides which hypotheses to keep and how they earn.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/hypotheses_updater.py`.

    * `Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.DefaultHypothesesUpdater`
      — **ported**: start the space, add a channel that joins late, add this
      observation's evidence, displace between steps.
    * `...BurstSampling.BurstSamplingHypothesesUpdater` — **ported**: the same
      job, but spending stalled steps on new hypotheses instead of only
      accumulating evidence. This is what experiments run.

  Monty's protocol also carries `evidence_threshold_config`, which the default
  updater ignores — it takes the threshold as an argument each step instead.
  """
end
