defmodule Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.Selector do
  @moduledoc """
  Deciding which channels take part in feature matching — the selector family.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/features_for_matching/selector.py`,
  a module holding a protocol and its default implementation:

    * `Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.Selector.FeaturesForMatchingSelector`
      is the protocol, as a behaviour;
    * `...Selector.DefaultFeaturesForMatchingSelector` is the default, and
      `...FeaturesForMatching.AllSelector` is the alternative Monty ships.

  The decision matters because a channel not used for features still
  contributes pose evidence: switching features off is not the same as ignoring
  the channel.
  """
end
