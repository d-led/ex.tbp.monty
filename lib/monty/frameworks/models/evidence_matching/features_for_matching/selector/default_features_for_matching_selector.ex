defmodule Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.Selector.DefaultFeaturesForMatchingSelector do
  @moduledoc """
  Features are matched when the experiment asked for them.

  Mirrors
  `tbp/monty/frameworks/models/evidence_matching/features_for_matching/selector.py::DefaultFeaturesForMatchingSelector`.

  Two conditions, both of which have to hold for a channel to be matched on its
  features: the increment that scales feature evidence is above zero, and the
  channel weights at least one feature that is not a pose feature. A channel
  weighted only on `pose_vectors` is a channel matched by pose alone — that is
  a real way to run an experiment, not an omission.
  """

  @behaviour Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.Selector.FeaturesForMatchingSelector

  @pose_features ["pose_vectors", "pose_fully_defined"]

  @impl true
  def select(feature_evidence_increment, feature_weights, tolerances) do
    Map.new(tolerances, fn {input_channel, _tolerances} ->
      {input_channel,
       uses_features?(feature_evidence_increment, Map.get(feature_weights, input_channel))}
    end)
  end

  defp uses_features?(increment, _weights) when increment <= 0, do: false
  defp uses_features?(_increment, nil), do: false

  defp uses_features?(_increment, weights) do
    weights
    |> Map.keys()
    |> Enum.any?(&(&1 not in @pose_features))
  end
end
