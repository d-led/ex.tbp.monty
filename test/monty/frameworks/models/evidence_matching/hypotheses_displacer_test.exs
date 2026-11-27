defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.EvidenceMatching.PoseKind
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry
  alias Monty.Geometry.Rotation

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  # The same frame turned half a turn about z: the normal is unchanged and the
  # two curvature directions point the other way.
  @pose_turned [0.0, 0.0, 1.0, -1.0, 0.0, 0.0, 0.0, -1.0, 0.0]
  # An object orientation, as nine numbers row by row: the frame itself, and the
  # same frame turned half a turn about z.
  @identity_orientation [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
  @half_turned_orientation [-1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0]
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

      assert Hypotheses.evidence(after_move) == Hypotheses.evidence(before)
      assert Hypotheses.poses(after_move) == Hypotheses.poses(before)
    end

    # A walk is a sequence, not one step that replaces the last: every step adds
    # to where the hypothesis already is, so walking there and back leaves it
    # where it started. Displacing the hypotheses sampled at the start of the
    # episode, instead of the ones displaced last step, leaves them on the nodes
    # they were drawn from for the whole run — which was, measured against
    # Monty on the same walk, the difference between a wrong object's evidence
    # decaying to nothing and its rising forever.
    test "a hypothesis walks with the sensor, so a step and its step back return it" do
      there =
        displacer()
        |> HypothesesDisplacer.displace_hypotheses(hypotheses([1.0], [[0.0, 0.0, 0.0]]), [
          0.25,
          0.0,
          0.0
        ])
        |> then(&HypothesesDisplacer.displace_hypotheses(displacer(), &1, [0.0, 0.25, 0.0]))

      back =
        displacer()
        |> HypothesesDisplacer.displace_hypotheses(there, [0.0, -0.25, 0.0])
        |> then(&HypothesesDisplacer.displace_hypotheses(displacer(), &1, [-0.25, 0.0, 0.0]))

      assert [location] = Hypotheses.locations(back)
      assert Enum.all?(location, &(abs(&1) < 1.0e-9))
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

      assert [evidence] = Hypotheses.evidence(updated)
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

      assert [evidence] = Hypotheses.evidence(updated)
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

      assert [evidence] = Hypotheses.evidence(updated)
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

      assert hd(Hypotheses.evidence(half)) < hd(Hypotheses.evidence(full))
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

      assert_in_delta hd(Hypotheses.evidence(updated)), -1.0, 1.0e-9
    end

    # test_clamps_neighbors_to_channel_node_count
    test "a channel with fewer nodes than the neighbour count is judged on the nodes it has" do
      # Two nodes, five neighbours asked for: the comparison is the one the two
      # of them give, and asking for one changes nothing either — a neighbour
      # count above the graph reaches nothing past it.
      assert earned(displacer(max_nneighbors: 5), features()) ==
               earned(displacer(max_nneighbors: 1), features())
    end

    # test_prediction_error_computed_from_summed_evidence
    test "the prediction error is what both channels earned between them" do
      # Channel a's node is where the hypothesis is, so a matches and earns 2;
      # channel b's node is a metre off with a half-metre reach, so b earns -1.
      # Two channels can earn four between them and this hypothesis earned one,
      # so half the range is missing: 0.5.
      {_updated, telemetry} =
        HypothesesDisplacer.compute_evidence(
          asymmetric_displacer(),
          %{"a" => channel_features(), "b" => channel_features()},
          0.0,
          "mug",
          hypotheses([5.0], [[0.0, 0.0, 0.0]])
        )

      assert telemetry.mlh_prediction_error == 0.5

      # Channel a alone is a perfect match. What moves the error is b's
      # contribution, and it moves it by being summed.
      {_one, alone} =
        HypothesesDisplacer.compute_evidence(
          asymmetric_displacer(),
          %{"a" => channel_features()},
          0.0,
          "mug",
          hypotheses([5.0], [[0.0, 0.0, 0.0]])
        )

      assert alone.mlh_prediction_error == 0.0
    end

    # What a run does to a wrong object: its hypotheses are carried along by the
    # sensor, and once the walk has taken them off the graph they earn nothing —
    # that is the evidence decay the slope tracker deletes them on, and without
    # it nothing is ever pruned and no episode concludes. The graph here holds
    # two nodes a decimetre apart with a half-metre reach, so a quarter of a
    # metre a step leaves the second node behind and the third step leaves both.
    test "a hypothesis carried off the object stops earning evidence" do
      {_walked, series} =
        Enum.reduce(1..3, {hypotheses([0.0], [[0.0, 0.0, 0.0]]), []}, fn _step,
                                                                         {walked, series} ->
          walked = HypothesesDisplacer.displace_hypotheses(displacer(), walked, [0.25, 0.0, 0.0])

          {updated, _} =
            HypothesesDisplacer.compute_evidence(displacer(), features(), 0.0, "mug", walked)

          {updated, [hd(Hypotheses.evidence(updated)) | series]}
        end)

      assert Enum.reverse(series) == [2.0, 4.0, 3.0]
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

      assert Hypotheses.evidence(updated) == [0.1]
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

  # Monty's `test_multi_channel_evidence_sums`: what a step earns is the sum of
  # what each channel earned. Monty stubs the per-channel evidence out; here two
  # channels over the same graph earn it for real, one channel at a time and
  # then both, and the total has to be the sum.
  #
  # The three `_calculate_evidence_for_new_locations_*` cases below belong to the
  # same group in Monty's file and record a dispatch: the distance rule and the
  # pose evidence are chosen by the channel's pose type (§2.50). Monty asserts it
  # by patching the three functions and counting calls; a patched function says
  # nothing about the numbers, so each case here is the number only that rule can
  # produce — the same geometry scored by the rule Monty's branch would not have
  # taken.
  describe "the rule a channel's distance and pose evidence follow (§2.50)" do
    # test_calculate_evidence_for_new_locations_invoke_custom_distances_for_surface_pose_vectors
    test "a surface channel measures in its tangent plane, so five centimetres off a flat surface is out of reach" do
      # Curvature zero is a flat surface: the penalty for leaving its plane is
      # the strongest there is, and this node sits five centimetres above it with
      # a reach of ten.
      {updated, _telemetry} =
        HypothesesDisplacer.compute_evidence(
          displacer_over(@pose, 0.1),
          surface_features(),
          0.0,
          "mug",
          hypotheses([0.0], [[0.0, 0.0, 0.05]])
        )

      assert Hypotheses.evidence(updated) == [-1.0]
    end

    # test_calculate_evidence_for_new_locations_invoke_euclidean_distances_for_orientation_matrix_pose_vectors
    test "an orientation channel measures the plain distance, so the same five centimetres is a match" do
      {updated, _telemetry} =
        HypothesesDisplacer.compute_evidence(
          displacer_over(@identity_orientation, 0.1),
          orientation_features(),
          0.0,
          "mug",
          hypotheses([0.0], [[0.0, 0.0, 0.05]])
        )

      assert [earned] = Hypotheses.evidence(updated)
      assert earned > 0.0
    end

    # test_calculate_evidence_for_new_locations_invokes_object_pose_evidence_for_orientation_matrix_pose_vectors
    test "an orientation channel scores the rotation, which a surface channel cannot see" do
      # Two stored frames that differ by half a turn about z. As rotations they
      # are as far apart as two rotations can be, so the orientation channel is
      # worth two less against one than against the other.
      against_identity =
        earned(displacer_over(@identity_orientation, 0.5), orientation_features())

      against_turned =
        earned(displacer_over(@half_turned_orientation, 0.5), orientation_features())

      assert against_identity - against_turned == 2.0

      # A surface reads the same two frames as equal — the normal is unchanged,
      # and a curvature direction has no sign — so it sees no difference at all.
      assert earned(displacer_over(@pose, 0.5), surface_features()) ==
               earned(displacer_over(@pose_turned, 0.5), surface_features())
    end
  end

  defp earned(displacer, features) do
    {updated, _telemetry} =
      HypothesesDisplacer.compute_evidence(
        displacer,
        features,
        0.0,
        "mug",
        hypotheses([0.0], [[0.0, 0.0, 0.0]])
      )

    [earned] = Hypotheses.evidence(updated)
    earned
  end

  # One node at the origin carrying `pose_row`, and a displacer over it that
  # reaches `max_match_distance`.
  defp displacer_over(pose_row, max_match_distance) do
    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(
        [[0.0, 0.0, 0.0]],
        %{
          "pose_vectors" => [pose_row],
          "pose_fully_defined" => [[1.0]],
          "rgba" => [[0.2]]
        },
        nil,
        nil
      )

    memory =
      GraphMemory.new(
        features_to_use: %{"patch" => ["pose_vectors", "pose_fully_defined", "rgba"]}
      )
      |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
      |> GraphMemory.initialize_feature_arrays()

    HypothesesDisplacer.new(memory,
      feature_weights: %{"patch" => %{"pose_vectors" => [1.0, 1.0, 1.0], "rgba" => 1.0}},
      max_match_distance: max_match_distance,
      tolerances: %{"patch" => %{"rgba" => 0.1}}
    )
  end

  defp surface_features do
    %{
      "patch" => %{
        "pose_vectors" => @pose,
        "pose_fully_defined" => true,
        "rgba" => [0.2],
        "principal_curvatures_log" => [0.0, 0.0],
        PoseKind.key() => :surface_pose_vectors
      }
    }
  end

  defp orientation_features do
    %{
      "patch" => %{
        "pose_vectors" => @identity_orientation,
        "pose_fully_defined" => true,
        "rgba" => [0.2],
        PoseKind.key() => :orientation_matrix
      }
    }
  end

  describe "Monty's multi-channel case" do
    # test_multi_channel_evidence_sums
    test "two channels' evidence is summed, and added to what the hypotheses had" do
      settled = two_channel_displacer()
      start = hypotheses([1.0, 2.0, 3.0], [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]])

      {one, _} =
        HypothesesDisplacer.compute_evidence(
          settled,
          %{"a" => channel_features()},
          0.0,
          "mug",
          start
        )

      {other, _} =
        HypothesesDisplacer.compute_evidence(
          settled,
          %{"b" => channel_features()},
          0.0,
          "mug",
          start
        )

      {both, _} =
        HypothesesDisplacer.compute_evidence(
          settled,
          %{"a" => channel_features(), "b" => channel_features()},
          0.0,
          "mug",
          start
        )

      sums =
        Enum.zip_with(Hypotheses.evidence(one), Hypotheses.evidence(other), fn left, right ->
          left + right
        end)

      assert Hypotheses.evidence(both) == sums
    end
  end

  # Two channels over one node apiece, and the weights that leave the new
  # evidence bare: `past_weight: 0` forgets what a hypothesis had, so what is
  # left is what this step's channels earned.
  defp two_channel_displacer do
    features_to_use = %{
      "a" => ["pose_vectors", "pose_fully_defined", "rgba"],
      "b" => ["pose_vectors", "pose_fully_defined", "rgba"]
    }

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(
        [[0.0, 0.0, 0.0]],
        %{"pose_vectors" => [@pose], "pose_fully_defined" => [[1.0]], "rgba" => [[0.2]]},
        nil,
        nil
      )

    memory =
      GraphMemory.new(features_to_use: features_to_use)
      |> GraphMemory.add_graph_to_memory(%{"a" => model, "b" => model}, "mug")
      |> GraphMemory.initialize_feature_arrays()

    HypothesesDisplacer.new(memory,
      feature_weights: %{
        "a" => %{"pose_vectors" => [1.0, 1.0, 1.0], "rgba" => 1.0},
        "b" => %{"pose_vectors" => [1.0, 1.0, 1.0], "rgba" => 1.0}
      },
      max_match_distance: 0.5,
      tolerances: %{"a" => %{"rgba" => 0.1}, "b" => %{"rgba" => 0.1}},
      past_weight: 0,
      present_weight: 1
    )
  end

  defp channel_features,
    do: %{"pose_vectors" => @pose, "pose_fully_defined" => true, "rgba" => [0.2]}

  # Two channels whose nodes are a metre apart: a hypothesis at the origin sits
  # on channel a's node and is out of reach of channel b's.
  defp asymmetric_displacer do
    node_at = fn location ->
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(
        [location],
        %{"pose_vectors" => [@pose], "pose_fully_defined" => [[1.0]], "rgba" => [[0.2]]},
        nil,
        nil
      )
    end

    features_to_use = %{
      "a" => ["pose_vectors", "pose_fully_defined", "rgba"],
      "b" => ["pose_vectors", "pose_fully_defined", "rgba"]
    }

    memory =
      GraphMemory.new(features_to_use: features_to_use)
      |> GraphMemory.add_graph_to_memory(
        %{"a" => node_at.([0.0, 0.0, 0.0]), "b" => node_at.([1.0, 0.0, 0.0])},
        "mug"
      )
      |> GraphMemory.initialize_feature_arrays()

    HypothesesDisplacer.new(memory,
      feature_weights: %{
        "a" => %{"pose_vectors" => [1.0, 1.0, 1.0], "rgba" => 1.0},
        "b" => %{"pose_vectors" => [1.0, 1.0, 1.0], "rgba" => 1.0}
      },
      max_match_distance: 0.5,
      tolerances: %{"a" => %{"rgba" => 0.1}, "b" => %{"rgba" => 0.1}},
      past_weight: 0,
      present_weight: 1
    )
  end

  # Monty's `ObjectPoseEvidenceTest` — the `` clause of PR #1266: a channel whose
  # pose is an object orientation is scored by how far two rotations are apart,
  # scaled so 0° is 1 and 180° is -1.
  describe "object_pose_evidence/2" do
    # test_object_orientations_map_0_to_pi_onto_1_to_neg1_interval_respectively
    property "maps 0 to π onto 1 to -1, whatever the poses are" do
      check all(
              query_poses <- list_of(rotation_matrix(), max_length: 3),
              axis <- unit_vector(),
              angle <- StreamData.float(min: 0.0, max: :math.pi())
            ) do
        # The stored pose is the query turned by `angle` about `axis`, so the
        # relative rotation is exactly that angle however the query is turned.
        turn = Rotation.from_axis_angle(axis, angle) |> elem(1) |> Rotation.to_matrix()
        node_poses = Enum.map(query_poses, fn query -> [flat(Geometry.mul(query, turn))] end)

        evidence = HypothesesDisplacer.object_pose_evidence(query_poses, node_poses)

        for [earned] <- evidence do
          # The angle comes off a trace of a product of two rotation matrices,
          # so it is only nearly exact — at 0° the cosine sits a rounding error
          # away from 1, and `acos` amplifies that into the seventh decimal.
          assert_in_delta earned, 1 - 2 * angle / :math.pi(), 1.0e-6
        end
      end
    end
  end

  defp rotation_matrix do
    gen all(
          axis <- unit_vector(),
          angle <- StreamData.float(min: 0.0, max: 2 * :math.pi())
        ) do
      Rotation.from_axis_angle(axis, angle) |> elem(1) |> Rotation.to_matrix()
    end
  end

  defp unit_vector do
    gen all(
          x <- StreamData.float(min: -1.0, max: 1.0),
          y <- StreamData.float(min: -1.0, max: 1.0),
          z <- StreamData.float(min: -1.0, max: 1.0),
          SpatialArithmetics.magnitude([x, y, z]) > 0.05
        ) do
      SpatialArithmetics.normalize([x, y, z])
    end
  end

  defp flat([[a, b, c], [d, e, f], [g, h, i]]), do: [a, b, c, d, e, f, g, h, i]
end
