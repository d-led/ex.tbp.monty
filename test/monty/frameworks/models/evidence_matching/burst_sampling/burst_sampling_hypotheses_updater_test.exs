defmodule Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdaterTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater

  alias Monty.Frameworks.Models.EvidenceMatching.FeatureEvidence.Scorer.DefaultFeatureEvidenceScorer

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
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

    BurstSamplingHypothesesUpdater.new(
      graph_memory,
      Keyword.merge([displacer: displacer, scorer: scorer], options)
    )
  end

  defp features do
    %{"patch" => %{"pose_vectors" => @pose, "pose_fully_defined" => true, "rgba" => [0.2]}}
  end

  defp hypotheses do
    %Hypotheses{
      evidence: [1.0, 0.5],
      locations: [[0.0, 0.0, 0.0], [0.3, 0.0, 0.0]],
      poses: [@identity, @identity],
      possible: [true, true]
    }
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

      assert Enum.at(Enum.at(moved.locations, 0), 0) |> Float.round(6) == 0.1
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
      refute Enum.take(updated.locations, 2) == hypotheses().locations
      assert Enum.all?(updated.locations, fn [x | _] -> x <= 0.3 end)
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
  end
end
