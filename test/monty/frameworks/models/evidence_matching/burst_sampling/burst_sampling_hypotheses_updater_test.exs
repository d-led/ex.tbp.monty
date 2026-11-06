defmodule Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdaterTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Geometry
  alias Monty.Geometry.Rotation

  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  @identity Rotation.to_matrix(Rotation.identity())

  # Four nodes a decimetre apart, all facing the same way, curvature stored.
  defp memory do
    locations = for index <- 0..3//1, do: [index / 10, 0.0, 0.0]

    features = %{
      "rgba" => Enum.map(locations, fn [x | _] -> [x] end),
      "pose_vectors" => List.duplicate(@pose, 4)
    }

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(locations, features, nil, nil)

    GraphMemory.new(features_to_use: %{"patch" => ["rgba", "pose_vectors"]})
    |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
    |> GraphMemory.initialize_feature_arrays()
  end

  defp updater(options \\ []), do: updater_for(memory(), options)

  defp updater_for(graph_memory, options) do
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

    BurstSamplingHypothesesUpdater.new(
      graph_memory,
      Keyword.merge([displacer: displacer, scorer: scorer], options)
    )
  end

  # Monty's tests write initial poses as Euler angles and invert them before
  # handing them to the updater; the upstream conversion does the same.
  defp inverse_rotation(euler_degrees) do
    {:ok, rotation} = Rotation.from_euler_degrees(euler_degrees)

    rotation |> Rotation.invert() |> Rotation.to_matrix()
  end

  defp features do
    %{"patch" => %{"pose_vectors" => @pose, "pose_fully_defined" => true, "rgba" => [0.2]}}
  end

  # The same graph, with its frames measured the way a real model measures them:
  # unit and perpendicular to a few parts in a thousand, and not a rotation.
  defp measured_memory do
    locations = [[0.0, 0.0, 0.0]]

    features = %{
      "rgba" => [[0.2]],
      "pose_vectors" => [
        [
          0.195_484,
          0.098_572,
          0.975_740,
          -0.334_766,
          -0.928_469,
          0.160_865,
          0.921_854,
          -0.357_946,
          -0.148_527
        ]
      ]
    }

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(locations, features, nil, nil)

    GraphMemory.new(features_to_use: %{"patch" => ["rgba", "pose_vectors"]})
    |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
    |> GraphMemory.initialize_feature_arrays()
  end

  defp hypotheses do
    Hypotheses.new(
      evidence: [1.0, 0.5],
      locations: [[0.0, 0.0, 0.0], [0.3, 0.0, 0.0]],
      poses: [@identity, @identity],
      possible: [true, true]
    )
  end

  describe "starting and ending a burst" do
    test "a burst starts when evidence has stalled" do
      assert BurstSamplingHypothesesUpdater.begin_step(updater(burst_sampling_duration: 3)).sampling_burst_steps ==
               3
    end

    test "no burst starts while one is already running" do
      started = BurstSamplingHypothesesUpdater.begin_step(updater(burst_sampling_duration: 3))
      again = BurstSamplingHypothesesUpdater.begin_step(started)

      assert again.sampling_burst_steps == 3
    end

    test "each step of a burst counts down, and the count never goes below zero" do
      counted =
        Enum.reduce(1..3, updater(burst_sampling_duration: 1), fn _step, updater ->
          updater
          |> BurstSamplingHypothesesUpdater.begin_step()
          |> BurstSamplingHypothesesUpdater.end_step()
        end)

      assert counted.sampling_burst_steps == 0
    end
  end

  describe "what it refuses" do
    test "a negative sampling multiplier, as Monty's constructor does" do
      # Monty's `test_init_fails_when_sampling_multiplier_is_negative`. A
      # negative multiplier asks a burst for a negative number of hypotheses,
      # which is not a count anyone can act on.
      assert_raise ArgumentError, ~r/sampling_multiplier should be >= 0/, fn ->
        updater(sampling_multiplier: -1.0)
      end
    end
  end

  describe "displacing" do
    test "with nothing to move by, nothing moves" do
      assert BurstSamplingHypothesesUpdater.displace_hypotheses(updater(), hypotheses(), nil) ==
               hypotheses()
    end

    test "with no hypotheses yet there is nothing to displace" do
      empty = Hypotheses.empty()

      assert BurstSamplingHypothesesUpdater.displace_hypotheses(updater(), empty, [0.1, 0.0, 0.0]) ==
               empty
    end

    test "otherwise every hypothesis moves by the step, as its pose sees it" do
      moved =
        BurstSamplingHypothesesUpdater.displace_hypotheses(updater(), hypotheses(), [
          0.1,
          0.0,
          0.0
        ])

      assert Enum.at(Enum.at(Hypotheses.locations(moved), 0), 0) |> Float.round(6) == 0.1
    end
  end

  describe "updating evidence" do
    test "a stalled update samples new hypotheses from the best-matching nodes" do
      # The multiplier is Monty's 0.4 by default, which over a three-node graph
      # asks for fewer than one hypothesis per pose set and so for none at all:
      # a burst is asked for here at a multiplier that a small graph can satisfy.
      {updater, updated, telemetry} =
        updater(sampling_multiplier: 3.0)
        |> BurstSamplingHypothesesUpdater.begin_step()
        |> then(fn updater ->
          BurstSamplingHypothesesUpdater.update_evidence(
            updater,
            hypotheses(),
            features(),
            "mug",
            0.0
          )
        end)

      assert Hypotheses.count(updated) > Hypotheses.count(hypotheses())
      assert telemetry.added_ids != []
      assert updater.sampling_burst_steps > 0
    end

    test "a burst asks for whole pose sets, one per pose on every node" do
      # Monty's `test_sample_count_proportional_multi_channel`, through the public
      # step: with P initial poses and a multiplier capped at P, a burst proposes
      # `nodes * min(multiplier, P)` hypotheses, floored to a multiple of P —
      # half a set of poses is not a hypothesis set.
      poses = for index <- 0..2, do: inverse_rotation([0.0, 0.0, index * 120.0])

      {_updater, _updated, telemetry} =
        updater(initial_possible_poses: poses, sampling_multiplier: 2.0)
        |> BurstSamplingHypothesesUpdater.begin_step()
        |> then(fn updater ->
          BurstSamplingHypothesesUpdater.update_evidence(
            updater,
            Hypotheses.empty(),
            features(),
            "mug",
            0.0
          )
        end)

      # Four nodes, a multiplier of two and three poses: 8 wanted, floored to 6.
      assert length(telemetry.added_ids) == 6
      assert rem(length(telemetry.added_ids), 3) == 0
    end

    test "a multiplier larger than the pose set is capped at one set per node" do
      # Monty's `min(sampling_multiplier, num_hyps_per_node)`: asking for ten when
      # the experiment named three poses still proposes three per node.
      poses = for index <- 0..2, do: inverse_rotation([0.0, 0.0, index * 120.0])

      {_updater, _updated, telemetry} =
        updater(initial_possible_poses: poses, sampling_multiplier: 10.0)
        |> BurstSamplingHypothesesUpdater.begin_step()
        |> then(fn updater ->
          BurstSamplingHypothesesUpdater.update_evidence(
            updater,
            Hypotheses.empty(),
            features(),
            "mug",
            0.0
          )
        end)

      assert length(telemetry.added_ids) == 4 * 3
    end

    test "an observation no channel of the graph carries updates nothing" do
      {_updater, updated, telemetry} =
        BurstSamplingHypothesesUpdater.update_evidence(
          updater(),
          hypotheses(),
          %{"depth" => %{}},
          "mug",
          0.0
        )

      assert updated == nil
      assert telemetry == %{}
    end

    test "the first update resamples, because there is no evidence history to keep" do
      {_updater, updated, _telemetry} =
        updater()
        |> BurstSamplingHypothesesUpdater.begin_step()
        |> then(fn updater ->
          BurstSamplingHypothesesUpdater.update_evidence(
            updater,
            hypotheses(),
            features(),
            "mug",
            0.0
          )
        end)

      # Nothing in the tracker yet means nothing is retained: Monty rebuilds the
      # space from the observation, and evidence starts accumulating from there.
      refute Enum.take(Hypotheses.locations(updated), 2) == Hypotheses.locations(hypotheses())
      assert Enum.all?(Hypotheses.locations(updated), fn [x | _] -> x <= 0.3 end)
    end

    test "the slope tracker follows the hypotheses from one step to the next" do
      {updater, _updated, _telemetry} =
        updater()
        |> BurstSamplingHypothesesUpdater.begin_step()
        |> then(fn updater ->
          BurstSamplingHypothesesUpdater.update_evidence(
            updater,
            hypotheses(),
            features(),
            "mug",
            0.0
          )
        end)

      assert map_size(updater.evidence_slope_trackers) == 1
    end

    # A sampled hypothesis is placed where a node of the model could be, and
    # turned onto it: the pose is the product that maps the sensed frame onto the
    # stored one. A stored frame is measured, not constructed — unit and
    # perpendicular only to a few parts in a thousand — so the product is only
    # nearly a rotation, and Monty keeps it that way. Rounding it into a rotation
    # instead turns the sensed surface normal onto a normal the model does not
    # hold, an error of hundredths of a radian in every later step's pose
    # evidence.
    test "a sampled pose turns the sensed surface normal onto the stored one exactly" do
      updater = updater_for(measured_memory(), sampling_multiplier: 3.0, umbilical_num_poses: 2)

      {_updater, sampled, _telemetry} =
        updater
        |> BurstSamplingHypothesesUpdater.begin_step()
        |> then(fn updater ->
          BurstSamplingHypothesesUpdater.update_evidence(
            updater,
            Hypotheses.empty(),
            features(),
            "mug",
            0.0
          )
        end)

      # The normal of the one stored node, as the model measured it, and the
      # sensed normal the observation reports.
      stored_normal = [0.195_484, 0.098_572, 0.975_740]
      sensed_normal = Enum.take(@pose, 3)

      assert Hypotheses.poses(sampled) != []

      assert Enum.all?(Hypotheses.poses(sampled), fn pose ->
               Geometry.apply(pose, sensed_normal) == stored_normal
             end)
    end
  end
end
