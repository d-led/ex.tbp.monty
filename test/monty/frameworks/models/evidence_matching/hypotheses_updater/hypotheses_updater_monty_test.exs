defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.HypothesesUpdaterMontyTest do
  @moduledoc """
  Monty's own cases for the hypotheses updater's informed poses, translated.

  Each test names the case in
  `tests/unit/frameworks/models/evidence_matching/hypotheses_updater_test.py` it
  translates. Monty's class patches `possible_sensed_directions` and
  `align_multiple_orthonormal_vectors` and asserts how often they were called and
  with what; the claim underneath is how many hypotheses the first observation
  starts — a node per stored location, a pose per sensed direction — so that is
  what is asserted, through `update_evidence`, which is the public entry that
  reaches the private function the mocks were standing around. The fixtures are
  the ones beside this file: a graph of three nodes and one channel.

  ## The second pose type

  Two cases are about a pose vector that is an `OrientationMatrix` rather than
  surface pose vectors. The port's updater had no clause for it — it read nine
  numbers and built a `%SurfacePoseVectors{}` — so the first translation of this
  file listed them as untranslatable. `sensed_pose_vectors/1` became
  `pose_vectors/1` with Monty's three branches (surface pose vectors enumerate
  directions, an orientation matrix is aligned as it stands, anything else is
  refused by name), and the two cases are now translated against it.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.DefaultHypothesesUpdater
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.{OrientationMatrix, Rotation}

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @nodes 3

  defp memory do
    locations = for index <- 0..(@nodes - 1)//1, do: [index / 10, 0.0, 0.0]

    features = %{
      "rgba" => Enum.map(locations, fn [x | _] -> [x] end),
      "pose_vectors" => List.duplicate(@pose, @nodes),
      "pose_fully_defined" => List.duplicate([1.0], @nodes)
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

  defp features(pose_vectors, pose_fully_defined) do
    channel = %{"pose_vectors" => pose_vectors, "rgba" => [0.2]}

    channel =
      if pose_fully_defined == nil,
        do: channel,
        else: Map.put(channel, "pose_fully_defined", pose_fully_defined)

    %{"patch" => channel}
  end

  # An `OrientationMatrix` is already a frame: its three rows are the basis, so
  # nothing is enumerated from it.
  defp orientation_matrix do
    %OrientationMatrix{
      value: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
    }
  end

  defp started(updater, pose_vectors, pose_fully_defined) do
    {_updater, started, _telemetry} =
      DefaultHypothesesUpdater.update_evidence(
        updater,
        Hypotheses.empty(),
        features(pose_vectors, pose_fully_defined),
        "mug",
        0.0
      )

    started
  end

  # test_calls_for_two_possible_sensed_directions_when_surface_pose_vectors_and_pose_fully_defined
  test "a fully defined surface pose allows two sensed directions, so two poses a node" do
    started = started(updater(), @pose, true)

    assert Hypotheses.count(started) == @nodes * 2
  end

  # test_calls_for_umbilical_num_possible_sensed_directions_when_surface_pose_vectors_and_pose_not_fully_defined
  test "a surface pose that is not fully defined allows as many directions as configured" do
    # Monty asserts the count it hands `possible_sensed_directions`; here the
    # count that comes out of the updater is what says so.
    started = started(updater(umbilical_num_poses: 5), @pose, false)

    assert Hypotheses.count(started) == @nodes * 5
  end

  # test_uses_sensed_directions_for_orientation_matrix
  test "an orientation matrix is aligned against the stored frames as it stands" do
    # No direction is enumerated from it: one pose per node, not two — and Monty's
    # case passes no `pose_fully_defined`, because a matrix has no such flag.
    started = started(updater(), orientation_matrix(), nil)

    assert Hypotheses.count(started) == @nodes
  end

  # test_raises_type_error_for_unsupported_pose_vector_type
  test "a pose vector of a type the updater cannot use is refused by name" do
    assert_raise ArgumentError, ~r/Unsupported pose_vector type/, fn ->
      started(updater(), "unsupported_type", nil)
    end
  end

  # The fixture's rotations come from the graph, and the first pose is the
  # identity: this keeps the assertions above honest about what is counted.
  test "the graph's own rotations are kept, not replaced" do
    started =
      started(
        updater(initial_possible_poses: [Rotation.to_matrix(Rotation.identity())]),
        @pose,
        true
      )

    assert Hypotheses.count(started) == @nodes
  end
end
