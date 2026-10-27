defmodule Monty.Frameworks.Models.EvidenceMatching.Channels do
  @moduledoc """
  Which of the observed input channels can be matched against the graph.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/channels.py`. A channel
  is usable when the sensor delivered it *and* the graph stores it; either half
  missing leaves nothing to compare, so the channel drops out of the match
  rather than counting as a mismatch for every hypothesis.

  Monty notes that confidence in a channel is not consulted here — the
  observation does not carry it yet. When it does, this is the function that
  will read it.
  """

  @doc """
  The channels present in `features` and stored in `all_input_channels`.

  The order is the observation's, not the graph's: downstream code walks the
  channels it was handed and expects the same order the sensor produced.
  """
  @spec all_usable_input_channels(%{optional(String.t()) => term()}, [String.t()]) ::
          [String.t()]
  def all_usable_input_channels(features, all_input_channels) do
    Enum.filter(Map.keys(features), &(&1 in all_input_channels))
  end
end
