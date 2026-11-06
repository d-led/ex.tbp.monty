defmodule Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdaterTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater

  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker
  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker.HypothesesSelection

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
      # A trained graph stores whether each node's pose is well defined; a step
      # that has to say what a node's pose *is* reads it.
      "pose_fully_defined" => List.duplicate(true, 4),
      "pose_vectors" => List.duplicate(@pose, 4)
    }

    model =
      GraphObjectModel.new("mug")
      |> GraphObjectModel.build_model(locations, features, nil, nil)

    GraphMemory.new(features_to_use: %{"patch" => ["rgba", "pose_fully_defined", "pose_vectors"]})
    |> GraphMemory.add_graph_to_memory(%{"patch" => model}, "mug")
    |> GraphMemory.initialize_feature_arrays()
  end

  defp updater(options \\ []), do: updater_for(memory(), options)

  defp updater_for(graph_memory, options) do
    {stalled, options} = Keyword.pop(options, :stalled_tracker, false)
    {tracker, options} = Keyword.pop(options, :tracker)

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

    updater =
      BurstSamplingHypothesesUpdater.new(
        graph_memory,
        Keyword.merge([displacer: displacer, scorer: scorer], options)
      )

    trackers =
      case {stalled, tracker} do
        {true, _} -> stalled_tracker()
        {false, nil} -> nil
        {false, {first, next}} -> tracker_from(first, next)
      end

    if trackers, do: %{updater | evidence_slope_trackers: %{"mug" => trackers}}, else: updater
  end

  # Monty's tests write initial poses as Euler angles and invert them before
  # handing them to the updater; the upstream conversion does the same.
  defp inverse_rotation(euler_degrees) do
    {:ok, rotation} = Rotation.from_euler_degrees(euler_degrees)

    rotation |> Rotation.invert() |> Rotation.to_matrix()
  end

  # Monty's tests hand the updater a tracker whose slopes sit below the burst
  # trigger so that the next step is stalled by construction.
  defp stalled_tracker, do: tracker_from([0.0, 0.0, 0.0], [0.5, 0.5, 0.5])

  defp tracker_from(first, next) do
    tracker = EvidenceSlopeTracker.new(min_age: 0) |> EvidenceSlopeTracker.add_hyp(length(first))
    {:ok, tracker} = EvidenceSlopeTracker.update(tracker, first)
    {:ok, tracker} = EvidenceSlopeTracker.update(tracker, next)
    tracker
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

  describe "dropping hypotheses" do
    test "the values follow their hypotheses when a subset survives" do
      # Translated from `test_update_hypotheses_ids_map_correctly`. Monty mocks
      # a tracker to drop three of five and flags the second and third
      # differently; here a real tracker reaches that selection — only
      # hypotheses 1 and 2 climb — and the assertion is the same: the flags and
      # the places come back in their own order, not shifted.
      tracker =
        EvidenceSlopeTracker.new(min_age: 0)
        |> EvidenceSlopeTracker.add_hyp(5)
        |> then(&elem(EvidenceSlopeTracker.update(&1, [0.0, 0.0, 0.0, 0.0, 0.0]), 1))
        |> then(&elem(EvidenceSlopeTracker.update(&1, [0.0, 10.0, 10.0, 0.0, 0.0]), 1))

      assert tracker
             |> EvidenceSlopeTracker.select_hypotheses(0.5)
             |> HypothesesSelection.ids_to_retain() == [1, 2]

      hypotheses =
        Hypotheses.new(
          evidence: [0.0, 1.0, 2.0, 3.0, 4.0],
          locations: for(index <- 0..4, do: [index * 1.0, 0.0, 0.0]),
          poses: List.duplicate(Enum.chunk_every(@pose, 3), 5),
          possible: [false, true, false, false, false]
        )

      {_updater, updated, _telemetry} =
        %{updater() | evidence_slope_trackers: %{"mug" => tracker}}
        |> BurstSamplingHypothesesUpdater.update_evidence(hypotheses, features(), "mug", 0.0)

      assert Enum.map(Hypotheses.locations(updated), fn [x | _] -> round(x) end) == [1, 2]
      assert updated.possible == [true, false]
    end
  end

  describe "when a burst starts and how long it lasts" do
    test "a first step with nothing measured is stalled, whatever the trigger slope" do
      # Monty's `test_burst_triggers_on_first_step_with_no_trackers` (a property
      # over every duration) and `test_max_global_slope_returns_inf_when_no_trackers`:
      # with no slopes measurable the maximum is -inf, which is below every
      # trigger threshold, so a burst opens. A BEAM float cannot hold -inf, so
      # this port says `nil` for "nothing measurable" and counts that as stalled.
      for duration <- 1..10 do
        updater =
          updater(burst_sampling_duration: duration)
          |> BurstSamplingHypothesesUpdater.begin_step()

        assert updater.max_slope == nil
        assert updater.sampling_burst_steps == duration
      end
    end

    test "a slope at or below the threshold opens a burst and is what gets recorded" do
      # Translated from `test_burst_triggers_when_max_slope_at_or_below_threshold`:
      # slopes 0.25, 0.3 and -0.2, so the maximum is 0.3, under the 1.0 trigger.
      updater =
        updater(
          burst_trigger_slope: 1.0,
          burst_sampling_duration: 5,
          tracker: {[0.0, 0.2, 0.1], [0.25, 0.5, -0.1]}
        )
        |> BurstSamplingHypothesesUpdater.begin_step()

      assert_in_delta updater.max_slope, 0.3, 1.0e-9
      assert updater.sampling_burst_steps == 5
    end

    test "a slope above the threshold opens nothing" do
      # Translated from `test_burst_does_not_trigger_when_max_slope_above_threshold`:
      # every slope is 2.0, twice the trigger, so there is evidence still to be
      # had from another observation.
      updater =
        updater(
          burst_trigger_slope: 1.0,
          burst_sampling_duration: 5,
          tracker: {[0.0, 0.0, 0.0], [2.0, 2.0, 2.0]}
        )
        |> BurstSamplingHypothesesUpdater.begin_step()

      assert_in_delta updater.max_slope, 2.0, 1.0e-9
      assert updater.sampling_burst_steps == 0
    end

    test "a burst already under way is not restarted" do
      # Translated from `test_burst_does_not_trigger_when_already_in_burst`. The
      # count is what a burst has left, so restarting it would stretch the burst
      # and sample more hypotheses than Monty does.
      updater =
        updater(
          burst_trigger_slope: 1.0,
          burst_sampling_duration: 5,
          stalled_tracker: true
        )
        |> Map.put(:sampling_burst_steps, 3)
        |> BurstSamplingHypothesesUpdater.begin_step()

      assert updater.sampling_burst_steps == 3
    end

    test "ending a burst step counts it down, and a finished burst stays finished" do
      # Translated from `test_sampling_burst_steps_decrements_in_exit` and
      # `test_sampling_burst_steps_does_not_go_negative`.
      assert %{sampling_burst_steps: 2} =
               updater()
               |> Map.put(:sampling_burst_steps, 3)
               |> BurstSamplingHypothesesUpdater.end_step()

      assert %{sampling_burst_steps: 0} =
               updater()
               |> Map.put(:sampling_burst_steps, 0)
               |> BurstSamplingHypothesesUpdater.end_step()
    end

    test "a burst lasts exactly its duration, then stops" do
      # Translated from `test_burst_lasts_exactly_sampling_burst_duration_steps`.
      # Entering is Monty's `__enter__`, ending its `__exit__`; re-triggering is
      # prevented while a burst is under way, so the count only falls.
      updater =
        updater(burst_trigger_slope: 1.0, burst_sampling_duration: 5, stalled_tracker: true)

      {history, updater} =
        Enum.map_reduce(1..5, updater, fn _step, updater ->
          updater = BurstSamplingHypothesesUpdater.begin_step(updater)
          {updater.sampling_burst_steps, BurstSamplingHypothesesUpdater.end_step(updater)}
        end)

      assert history == [5, 4, 3, 2, 1]
      assert updater.sampling_burst_steps == 0
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
