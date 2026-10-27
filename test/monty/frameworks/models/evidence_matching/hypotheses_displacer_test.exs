defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacerTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry.Rotation

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @identity Rotation.to_matrix(Rotation.identity())

  # Two nodes a decimetre apart, both facing +z with a defined pose.
  defp memory do
    locations = [[0.0, 0.0, 0.0], [0.1, 0.0, 0.0]]

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(
        locations,
        %{
          "pose_vectors" => [@pose, @pose],
          "pose_fully_defined" => [[1.0], [1.0]],
          "rgba" => [[0.2], [0.2]]
        },
        nil,
        nil
      )

    GraphMemory.new(features_to_use: %{"patch" => ["pose_vectors", "pose_fully_defined", "rgba"]})
    |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
    |> GraphMemory.initialize_feature_arrays()
  end

  defp displacer(options \\ []) do
    HypothesesDisplacer.new(
      memory(),
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
    %Hypotheses{
      evidence: evidence,
      locations: locations,
      poses: List.duplicate(@identity, length(evidence)),
      possible: List.duplicate(true, length(evidence))
    }
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

      assert [location] = moved.locations
      assert_in_delta Enum.at(location, 0), 0.2, 1.0e-9
    end

    test "a turned hypothesis sees the same step differently" do
      {:ok, turn} = Rotation.from_axis_angle([0.0, 0.0, 1.0], :math.pi() / 2)
      pose = Rotation.to_matrix(turn)

      turned = %Hypotheses{
        evidence: [1.0],
        locations: [[0.0, 0.0, 0.0]],
        poses: [pose],
        possible: [true]
      }

      assert [location] =
               HypothesesDisplacer.displace_hypotheses(displacer(), turned, [0.2, 0.0, 0.0]).locations

      assert_in_delta Enum.at(location, 0), 0.0, 1.0e-9
      assert_in_delta Enum.at(location, 1), 0.2, 1.0e-9
    end

    test "the evidence and the poses are left alone" do
      before = hypotheses([0.7], [[0.0, 0.0, 0.0]])
      after_move = HypothesesDisplacer.displace_hypotheses(displacer(), before, [1.0, 0.0, 0.0])

      assert after_move.evidence == before.evidence
      assert after_move.poses == before.poses
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
