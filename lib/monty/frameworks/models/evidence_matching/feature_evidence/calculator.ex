defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator do
  @moduledoc """
  How much of a match a node's stored features are — the calculator family.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/feature_evidence/calculator.py`,
  a module holding a protocol and its default implementation. The Elixir split
  has the same shape:

    * `Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.FeatureEvidenceCalculator`
      is the protocol, as a behaviour;
    * `...Calculator.DefaultFeatureEvidenceCalculator` is the implementation an
      experiment gets unless it names another.

  A calculator is handed the stored features, the observed features and the
  tolerances, and answers with a score per node. It never touches graph memory:
  Monty injects the calculator into the hypotheses updater precisely so that
  scoring can be replaced without touching the search.
  """
end
