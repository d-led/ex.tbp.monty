defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.DefaultHypothesesUpdaterTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.DefaultHypothesesUpdater
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.Rotation

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @identity Rotation.to_matrix(Rotation.identity())

  defp memory do
    locations = for index <- 0..2//1, do: [index / 10, 0.0, 0.0]

    # A real graph stores the pose flag next to the vectors: the pose
    # comparison reads it, so a graph without it cannot be matched against.
    features = %{
      "rgba" => Enum.map(locations, fn [x | _] -> [x] end),
      "pose_vectors" => List.duplicate(@pose, 3),
      "pose_fully_defined" => [[1.0], [1.0], [1.0]]
    }

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(locations, features, nil, nil)

    GraphMemory.new(features_to_use: %{"patch" => ["rgba", "pose_vectors"]})
    |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
    |> GraphMemory.initialize_feature_arrays()
  end

  defp updater(options \\ []) do
    graph_memory = memory()

    scorer =
      DefaultFeatureEvidenceScorer.new(graph_memory,
        feature_weights: %{"patch" => %{"rgba" => 1.0}},
        tolerances: %{"patch" => %{"rgba" => 0.1}}
      )

    displacer =
      HypothesesDisplacer.new(graph_memory,
        feature_weights: %{"patch" => %{"pose_vectors" => [1.0, 1.0, 1.0], "rgba" => 1.0}},
        max_match_distance: 0.5,
        tolerances: %{"patch" => %{"rgba" => 0.1}},
        feature_evidence_scorer: scorer
      )

    DefaultHypothesesUpdater.new(
      graph_memory,
      Keyword.merge([displacer: displacer, scorer: scorer], options)
    )
  end

  defp features do
    %{"patch" => %{"pose_vectors" => @pose, "pose_fully_defined" => true, "rgba" => [0.2]}}
  end

  describe "the first step" do
    test "starts one hypothesis per node and pose, none of them ruled out" do
      {updater, started, telemetry} =
        DefaultHypothesesUpdater.update_evidence(
          updater(),
          Hypotheses.empty(),
          features(),
          "mug",
          0.0
        )

      assert Hypotheses.count(started) == 6
      assert Enum.all?(started.possible)
      assert telemetry == %{}
      assert MapSet.member?(updater.initialised_channels["mug"], "patch")
    end

    test "a node starts at the evidence its features are worth, not at zero" do
      {_updater, started, _telemetry} =
        DefaultHypothesesUpdater.update_evidence(
          updater(),
          Hypotheses.empty(),
          features(),
          "mug",
          0.0
        )

      # The nodes hold rgba 0.0, 0.1 and 0.2 and the sensor saw 0.2, so only the
      # third node starts with anything — once for each of the two poses a
      # defined surface pose allows.
      assert started.evidence == [0.0, 0.0, 1.0, 0.0, 0.0, 1.0]
    end

    test "fixed poses put every node under each configured rotation" do
      updater = updater(initial_possible_poses: [@identity])

      {_updater, started, _telemetry} =
        DefaultHypothesesUpdater.update_evidence(
          updater,
          Hypotheses.empty(),
          features(),
          "mug",
          0.0
        )

      assert Hypotheses.count(started) == 3
      assert Enum.all?(started.poses, &(&1 == @identity))
    end

    test "an observation no stored channel carries starts nothing" do
      {_updater, started, telemetry} =
        DefaultHypothesesUpdater.update_evidence(
          updater(),
          Hypotheses.empty(),
          %{"depth" => %{}},
          "mug",
          0.0
        )

      assert started == nil
      assert telemetry == %{}
    end
  end

  describe "later steps" do
    test "evidence is added to the hypotheses already there" do
      {updater, started, _telemetry} =
        DefaultHypothesesUpdater.update_evidence(
          updater(),
          Hypotheses.empty(),
          features(),
          "mug",
          0.0
        )

      {_updater, updated, telemetry} =
        DefaultHypothesesUpdater.update_evidence(updater, started, features(), "mug", 0.0)

      assert Hypotheses.count(updated) == Hypotheses.count(started)
      assert Enum.any?(updated.evidence, &(&1 > 0.0))
      assert is_float(telemetry.mlh_prediction_error)
    end

    test "a channel that joins late starts where the others already are" do
      {updater, started, _telemetry} =
        DefaultHypothesesUpdater.update_evidence(
          updater(),
          Hypotheses.empty(),
          features(),
          "mug",
          0.0
        )

      # Forget that the channel was ever started, then let it arrive again.
      updater = DefaultHypothesesUpdater.reset(updater)

      {_updater, joined, _telemetry} =
        DefaultHypothesesUpdater.update_evidence(updater, started, features(), "mug", 0.0)

      late = Enum.drop(joined.evidence, Hypotheses.count(started))
      assert late != []
      assert Enum.all?(late, &(&1 > 0.0))
    end
  end

  describe "displacing" do
    test "with no movement nothing moves" do
      hypotheses = %Hypotheses{
        evidence: [0.0],
        locations: [[0.0, 0.0, 0.0]],
        poses: [@identity],
        possible: [true]
      }

      assert DefaultHypothesesUpdater.displace_hypotheses(updater(), hypotheses, nil) ==
               hypotheses
    end

    test "with no hypotheses there is nothing to move" do
      assert DefaultHypothesesUpdater.displace_hypotheses(updater(), Hypotheses.empty(), [
               0.1,
               0.0,
               0.0
             ]) ==
               Hypotheses.empty()
    end
  end
end
