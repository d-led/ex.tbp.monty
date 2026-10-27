defmodule Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.AllSelector do
  @moduledoc """
  Features are matched whenever the experiment weighted the channel at all.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/features_for_matching/all_selector.py`,
  which is the alternative to the default selector: it does not ask whether a
  channel has any non-pose feature weights, only whether it was weighted at all.
  Naming this selector in an experiment means "match on what I configured,
  including a channel weighted only on poses".
  """

  @doc """
  Whether features are matched, per input channel — every weighted channel, as
  long as feature evidence counts for something.
  """
  @spec select(number(), %{optional(String.t()) => map()}, %{optional(String.t()) => map()}) ::
          %{optional(String.t()) => boolean()}
  def select(feature_evidence_increment, feature_weights, tolerances) do
    Map.new(tolerances, fn {input_channel, _tolerances} ->
      matched? = feature_evidence_increment > 0 and Map.has_key?(feature_weights, input_channel)
      {input_channel, matched?}
    end)
  end
end
