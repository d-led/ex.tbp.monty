defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacerTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.Rotation

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @identity Rotation.to_matrix(Rotation.identity())

  # Two nodes a decimetre apart unless the test asks for other places, both
  # facing +z with a defined pose.
  defp memory(locations) do
    count = length(locations)

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(
        locations,
        %{
          "pose_vectors" => List.duplicate(@pose, count),
          "pose_fully_defined" => List.duplicate([1.0], count),
          "rgba" => List.duplicate([0.2], count)
        },
        nil,
        nil
      )

    GraphMemory.new(features_to_use: %{"patch" => ["pose_vectors", "pose_fully_defined", "rgba"]})
    |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
    |> GraphMemory.initialize_feature_arrays()
  end

  defp displacer(options \\ []) do
    {locations, options} = Keyword.pop(options, :locations, [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]])

    HypothesesDisplacer.new(
      memory(locations),
      Keyword.merge(
        [
          feature_weights: %{"patch" => %{"pose_vectors" => [1.0, 1.0, 1.0], "rgba" => 1.0}},
          max_match_distance: 0.5,
          tolerances: %{"patch" => %{"rgba" => 0.1}}
        ],
        options
      )
    )
  end

  defp hypotheses(evidence, locations) do
    Hypotheses.new(
      evidence: evidence,
      locations: locations,
      poses: List.duplicate(@identity, length(evidence)),
      possible: List.duplicate(true, length(evidence))
    )
  end

  defp features do
    %{"patch" => %{"pose_vectors" => @pose, "pose_fully_defined" => true, "rgba" => [0.2]}}
  end

  describe "displace_hypotheses/3" do
    test "moves every hypothesis by the step, as its own orientation sees it" do
      moved =
        HypothesesDisplacer.displace_hypotheses(
          displacer(),
          hypotheses([1.0], [[0.0, 0.0, 0.0]]),
          [0.2, 0.0, 0.0]
        )

      assert [location] = Hypotheses.locations(moved)
      assert_in_delta Enum.at(location, 0), 0.2, 1.0e-9
    end

    test "a turned hypothesis sees the same step differently" do
      {:ok, turn} = Rotation.from_axis_angle([0.0, 0.0, 1.0], :math.pi() / 2)
      pose = Rotation.to_matrix(turn)

      turned =
        Hypotheses.new(
          evidence: [1.0],
          locations: [[0.0, 0.0, 0.0]],
          poses: [pose],
          possible: [true]
        )

      assert [location] =
               displacer()
               |> HypothesesDisplacer.displace_hypotheses(turned, [0.2, 0.0, 0.0])
               |> Hypotheses.locations()

      assert_in_delta Enum.at(location, 0), 0.0, 1.0e-9
      assert_in_delta Enum.at(location, 1), 0.2, 1.0e-9
    end

    test "the evidence and the poses are left alone" do
      before = hypotheses([0.7], [[0.0, 0.0, 0.0]])
      after_move = HypothesesDisplacer.displace_hypotheses(displacer(), before, [1.0, 0.0, 0.0])

      assert after_move.evidence == before.evidence
      assert Hypotheses.poses(after_move) == Hypotheses.poses(before)
    end
  end

  describe "compute_evidence/5" do
    test "a hypothesis sitting on a matching node earns evidence" do
      {updated, telemetry} =
        HypothesesDisplacer.compute_evidence(
          displacer(),
          features(),
          0.0,
          "mug",
          hypotheses([1.0], [[0.0, 0.0, 0.0]])
        )

      assert [evidence] = updated.evidence
      assert evidence > 1.0
      assert is_float(telemetry.mlh_prediction_error)
    end

    # The number the neighbourhood pass answers with, pinned. It used to be
    # computed a neighbour at a time with a list of evidence per hypothesis; the
    # walk is now one pass, and the arithmetic has to be the same arithmetic —
    # 0.5 for the normal, 0.5 for the first curvature direction, plus the node's
    # own feature evidence — so a change that moves it has to say so.
    test "a perfect match at a node earns 1 for its pose and 1 for its features" do
      {updated, _telemetry} =
        HypothesesDisplacer.compute_evidence(
          displacer(),
          features(),
          0.0,
          "mug",
          hypotheses([0.0], [[0.0, 0.0, 0.0]])
        )

      assert [evidence] = updated.evidence
      assert_in_delta evidence, 2.0, 1.0e-12
    end

    # Being nearest is not the same as being in range: the distance is flattened
    # along the sensed normal, so a node straight up from the search point scores
    # further away than one the same distance across it. The nearest of these two
    # is out of range and the other is not, and the hypothesis earns the best of
    # them rather than the nearest one's -1.
    test "a neighbour out of range does not spoil one that is in range" do
      {updated, _telemetry} =
        HypothesesDisplacer.compute_evidence(
          displacer(locations: [[0.0, 0.0, 0.49], [0.49, 0.0, 0.0]]),
          features(),
          0.0,
          "mug",
          hypotheses([0.0], [[0.0, 0.0, 0.0]])
        )

      assert [evidence] = updated.evidence
      assert_in_delta evidence, 2.0, 1.0e-12
    end

    test "past and present are weighted when combining evidence" do
      {full, _} =
        HypothesesDisplacer.compute_evidence(
          displacer(),
          features(),
          0.0,
          "mug",
          hypotheses([1.0], [[0.0, 0.0, 0.0]])
        )

      {half, _} =
        HypothesesDisplacer.compute_evidence(
          displacer(past_weight: 0.5, present_weight: 0.5),
          features(),
          0.0,
          "mug",
          hypotheses([1.0], [[0.0, 0.0, 0.0]])
        )

      assert hd(half.evidence) < hd(full.evidence)
    end

    test "a hypothesis with no node in range scores the worst possible evidence" do
      {updated, _} =
        HypothesesDisplacer.compute_evidence(
          displacer(),
          features(),
          0.0,
          "mug",
          hypotheses([0.0], [[9.0, 0.0, 0.0]])
        )

      assert_in_delta hd(updated.evidence), -1.0, 1.0e-9
    end

    test "a hypothesis below the threshold is not tested and gains nothing" do
      {updated, telemetry} =
        HypothesesDisplacer.compute_evidence(
          displacer(),
          features(),
          0.5,
          "mug",
          hypotheses([0.1], [[9.0, 0.0, 0.0]])
        )

      assert updated.evidence == [0.1]
      assert telemetry.mlh_prediction_error == nil
    end

    test "the prediction error reports how wrong the best hypothesis was" do
      {_updated, telemetry} =
        HypothesesDisplacer.compute_evidence(
          displacer(),
          features(),
          0.0,
          "mug",
          hypotheses([1.0], [[0.0, 0.0, 0.0]])
        )

      # Evidence can reach 2 per channel, so a good match is a small error.
      assert telemetry.mlh_prediction_error >= 0.0
      assert telemetry.mlh_prediction_error < 0.5
    end
  end
end
