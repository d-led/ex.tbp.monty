defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.FeatureEvidenceCalculator do
  @moduledoc """
  What a feature-evidence calculator has to be able to do.

  Mirrors
  `tbp/monty/frameworks/models/evidence_matching/feature_evidence/calculator.py::FeatureEvidenceCalculator`,
  which is a `Protocol`: any object with a `calculate` of this shape can be used
  as one. In Elixir that is a behaviour, and the hypotheses updater takes the
  calculator as a module, so an experiment can substitute its own — Monty's
  dependency injection, kept.

  ## Shapes

  `channel_feature_array` is one row per node, one column per stored feature
  value; `channel_feature_order` names the features in the order their columns
  appear. A multi-valued feature (`hsv` with three values) occupies three
  columns, and how many is read from the *query* features' values — that is the
  only place the length is written down, exactly as in Python.

  `pose_vectors` and `pose_fully_defined` are not feature evidence: they are
  compared as poses elsewhere and occupy no columns here.
  """

  @type row :: [float() | nil]
  @type feature_values :: number() | [number()]
  @type tolerance :: number() | [number()]

  @doc """
  Evidence in `[0, 1]` for every node in the graph, or `nil` where a node's
  stored values are missing.

  `nil` is this port's NaN: a value that is not a number is not a score, and
  callers must decide what a node without data means rather than have a
  comparison quietly go one way.
  """
  @callback calculate(
              channel_feature_array :: [row()],
              channel_feature_order :: [String.t()],
              channel_feature_weights :: %{optional(String.t()) => number()},
              channel_query_features :: %{optional(String.t()) => feature_values()},
              channel_tolerances :: %{optional(String.t()) => tolerance()}
            ) :: [float() | nil]
end
