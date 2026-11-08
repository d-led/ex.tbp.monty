defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.FeatureEvidenceScorer do
  @moduledoc """
  What a feature-evidence scorer has to be able to do.

  Mirrors
  `tbp/monty/frameworks/models/evidence_matching/feature_evidence/scorer.py::FeatureEvidenceScorer`,
  which is a `Protocol` and, here, a behaviour: given a graph, a channel and an
  observation, answer with one evidence value per node of that channel's graph.

  Monty's own note is that the name is a placeholder from a refactor; it is kept
  because an experiment that names a different scorer names this shape.
  """

  @doc """
  Evidence in `[0, 1]` per node, or `nil` where a node has no stored value.

  The first argument is the scorer's own configuration — Monty's `self`, which
  holds the graph memory, the weights and the tolerances. A channel that is not
  matched on its features answers all zeros: it still contributes pose evidence,
  which is computed elsewhere.
  """
  @callback evidence(
              scorer :: term(),
              graph_id :: String.t(),
              input_channel :: String.t(),
              query_features :: %{optional(String.t()) => term()}
            ) :: [float() | nil]
end
