defmodule Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTrackerParityTest do
  @moduledoc """
  The port answers what Monty answers, step for step.

  `scripts/record_monty_evidence_matching.py` ran Monty's own
  `EvidenceSlopeTracker` over a few scripted histories and wrote down what it
  answered after each one; this replays them. The unit tests pin each rule on its
  own — sliding, per-channel normalisation, NaN-aware averaging — while these pin
  the history, where the rules meet and a hypothesis's whole past decides its
  slope.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker
  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker.HypothesesSelection

  @fixture Path.expand("../../../../fixtures/monty_evidence_slope_tracker.json", __DIR__)

  setup_all do
    %{"histories" => histories} = @fixture |> File.read!() |> Jason.decode!()
    {:ok, histories: histories}
  end

  test "every recorded history is answered step for step", %{histories: histories} do
    for %{"window_size" => window, "min_age" => min_age, "steps" => steps} <- histories do
      tracker = EvidenceSlopeTracker.new(window_size: window, min_age: min_age)
      replay(tracker, steps)
    end
  end

  defp replay(tracker, [step | rest]) do
    tracker = apply_step(tracker, step)
    assert_state(tracker, step)
    replay(tracker, rest)
  end

  defp replay(_tracker, []), do: :ok

  defp apply_step(tracker, %{"op" => "add_hyp", "count" => count}),
    do: EvidenceSlopeTracker.add_hyp(tracker, count)

  defp apply_step(tracker, %{"op" => "update"} = step) do
    {:ok, updated} =
      EvidenceSlopeTracker.update(tracker, step["values"], num_channels: step["num_channels"])

    updated
  end

  defp apply_step(tracker, %{"op" => "remove_hyp", "indices" => indices}),
    do: EvidenceSlopeTracker.remove_hyp(tracker, indices)

  defp apply_step(tracker, %{"op" => "clear"}), do: EvidenceSlopeTracker.clear_hyp(tracker)
  defp apply_step(tracker, %{"op" => "select"}), do: tracker

  defp assert_state(tracker, step) do
    assert EvidenceSlopeTracker.total_size(tracker) == step["total_size"]
    assert EvidenceSlopeTracker.hyp_ages(tracker) == step["ages"]
    assert EvidenceSlopeTracker.removable_indices_mask(tracker) == step["removable"]
    assert_slopes(EvidenceSlopeTracker.calculate_slopes(tracker), step["slopes"])

    if Map.has_key?(step, "threshold") do
      selection = EvidenceSlopeTracker.select_hypotheses(tracker, step["threshold"])

      assert HypothesesSelection.ids_to_retain(selection) == step["ids_to_retain"]
      assert HypothesesSelection.ids_to_remove(selection) == step["ids_to_remove"]
    end
  end

  # Monty has one NaN and the port has one `nil`; both mean "no slope at all",
  # which a flat window's slope of zero must not be mistaken for.
  defp assert_slopes(port, monty) do
    assert length(port) == length(monty)

    monty
    |> Enum.zip(port)
    |> Enum.each(fn
      {nil, port_slope} -> assert is_nil(port_slope)
      {monty_slope, port_slope} -> assert_in_delta port_slope, monty_slope, 1.0e-12
    end)
  end
end
