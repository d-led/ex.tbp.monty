defmodule Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.AllSelector.AllFeaturesForMatchingSelector do
  @moduledoc """
  The `AllFeaturesForMatchingSelector` class of
  `features_for_matching/all_selector.py`.

  The selection is the one in `Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.AllSelector`;
  this module is the name Monty's experiments use, so that a config naming
  `AllFeaturesForMatchingSelector` resolves to something that behaves like the
  class it names.
  """

  @behaviour Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.Selector.FeaturesForMatchingSelector

  alias Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.AllSelector

  @impl true
  defdelegate select(feature_evidence_increment, feature_weights, tolerances),
    to: AllSelector
end
