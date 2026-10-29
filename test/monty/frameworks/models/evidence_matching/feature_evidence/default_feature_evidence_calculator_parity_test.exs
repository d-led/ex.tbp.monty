defmodule Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.DefaultFeatureEvidenceCalculatorParityTest do
  @moduledoc """
  The port answers what Monty answers, node for node.

  `scripts/record_monty_feature_evidence.py` ran Monty's own
  `DefaultFeatureEvidenceCalculator` over a few small graphs and wrote down what
  it answered; this replays them. The unit tests pin each rule — the linear
  falloff, the circular short way round, the categorical comparison — while
  these pin whole graphs, where the kinds of comparison and the per-feature
  weights meet in one number.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Calculator.DefaultFeatureEvidenceCalculator

  @fixture Path.expand("../../../../../fixtures/monty_feature_evidence.json", __DIR__)

  setup_all do
    %{"cases" => cases} = @fixture |> File.read!() |> Jason.decode!()
    {:ok, cases: cases}
  end

  test "every recorded graph is scored node for node", %{cases: cases} do
    for %{"expected" => expected} = recorded <- cases do
      evidence =
        DefaultFeatureEvidenceCalculator.calculate(
          recorded["rows"],
          recorded["feature_order"],
          recorded["feature_weights"],
          recorded["query_features"],
          recorded["tolerances"]
        )

      assert length(evidence) == length(expected)

      expected
      |> Enum.zip(evidence)
      |> Enum.each(fn
        {nil, port_evidence} -> assert is_nil(port_evidence)
        {monty_evidence, port_evidence} -> assert_in_delta port_evidence, monty_evidence, 1.0e-12
      end)
    end
  end
end
