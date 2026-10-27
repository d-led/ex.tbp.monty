defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer do
  @moduledoc """
  Turning one observation into evidence per node — the scorer family.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/feature_evidence/scorer.py`,
  a module holding a protocol and its default implementation:

    * `...FeatureEvidence.Scorer.FeatureEvidenceScorer` is the protocol, as a
      behaviour;
    * `...Scorer.DefaultFeatureEvidenceScorer` is what a learning module gets
      unless it names another.

  The scorer is where the three injected pieces meet: the calculator that turns
  stored features into scores, the selector that decides whether this channel is
  matched on its features at all, and the memory those features are read from.
  """
end
