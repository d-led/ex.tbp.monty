defmodule Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.Selector.FeaturesForMatchingSelector do
  @moduledoc """
  What a features-for-matching selector has to be able to do.

  Mirrors
  `tbp/monty/frameworks/models/evidence_matching/features_for_matching/selector.py::FeaturesForMatchingSelector`,
  a `Protocol` in Python and a behaviour here: an experiment chooses how the
  decision is made by naming a different module.
  """

  @doc """
  Whether features are matched, per input channel.

  `tolerances` names the channels in play; the result has one entry for each.
  """
  @callback select(
              feature_evidence_increment :: number(),
              feature_weights :: %{optional(String.t()) => map()},
              tolerances :: %{optional(String.t()) => map()}
            ) :: %{optional(String.t()) => boolean()}
end
