defmodule Monty.Frameworks.Models.EvidenceMatching.BurstSampling do
  @moduledoc """
  Spending steps on new hypotheses when the current ones stop learning.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/burst_sampling.py`.

    * `Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater`
      — **ported**: the sampling strategy Monty's evidence matching runs, which
      keeps, drops or replaces hypotheses between steps;
    * `...BurstSampling.BurstSamplingTelemetry` — **ported**: what a step reports
      about the hypotheses it added, kept and removed.

  `HypothesesUpdater` in the same family is the simpler strategy that only
  accumulates evidence; this one is what experiments use.
  """
end
