defmodule Monty.Frameworks.Utils.LoggingUtilsStatsTest do
  @moduledoc """
  The per-LM stats an episode's CSV and JSON are written from.

  Each case is a judgement the statistics make about a recognition, so each one is
  stated as the question it answers: did the module recognise the object it was
  asked about, was the graph it matched built from that object, and how far off was
  its pose. The module is built as a value, which is what lets a test say exactly
  what the episode did.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Utils.LoggingUtils
  alias Monty.Geometry.Rotation

  @identity_xyzw [0.0, 0.0, 0.0, 1.0]

  defp quarter_turn_xyzw do
    {:ok, rotation} = Rotation.from_euler_degrees([0.0, 90.0, 0.0])
    Rotation.to_xyzw(rotation)
  end

  # What the episode did to this module: on the object, what it concluded, and
  # which objects the graph it matched was built from.
  defp lm(overrides \\ []) do
    found =
      %{
        graph_id_to_target: %{"mug_graph" => MapSet.new(["mug"])},
        target_to_graph_id: %{"mug" => MapSet.new(["mug_graph"])},
        primary_target: "mug",
        primary_target_rotation_quat: @identity_xyzw,
        terminal_state: "match",
        detected_object: "mug_graph",
        detected_pose: [0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0],
        possible_matches: ["mug_graph"],
        symmetry_evidence: 2,
        buffer: buffer(%{"detected_rotation_quat" => @identity_xyzw, "time" => [1, 3]})
      }

    struct(EvidenceGraphLM, Map.merge(found, Map.new(overrides)))
  end

  defp buffer(stats) do
    %{
      FeatureAtLocationBuffer.new()
      | on_object: [1],
        locations: [[0.1, 0.0, 0.0]],
        stats: Map.merge(FeatureAtLocationBuffer.new().stats, stats)
    }
  end

  describe "a module that was never on the object" do
    test "has no performance and no steps, rather than a failure" do
      stats = LoggingUtils.graph_lm_episode_stats(lm(buffer: %{buffer(%{}) | on_object: [0]}))

      assert stats["primary_performance"] == "patch_off_object"
      assert stats["stepwise_performance"] == "patch_off_object"
      assert stats["num_steps"] == 0
      assert stats["result"] == nil
    end
  end

  describe "recognising the object it was asked about" do
    test "is correct, and the pose error is measured against the pose it was placed with" do
      stats =
        lm(
          primary_target_rotation_quat: quarter_turn_xyzw(),
          buffer: buffer(%{"detected_rotation_quat" => @identity_xyzw, "time" => [1, 3]})
        )
        |> LoggingUtils.graph_lm_episode_stats()

      assert stats["primary_performance"] == "correct"
      # The stepwise judgement is about the object it stood on, which nothing
      # recorded here — Monty's own reading, and the case with one is next.
      assert stats["stepwise_performance"] == "confused"
      assert stats["rotation_error"] == 90.0
      assert stats["result"] == "mug_graph"
    end

    test "is confused when the graph it matched was built from another object" do
      stats =
        lm(
          graph_id_to_target: %{"mug_graph" => MapSet.new(["bowl"])},
          target_to_graph_id: %{"bowl" => MapSet.new(["mug_graph"])}
        )
        |> LoggingUtils.graph_lm_episode_stats()

      assert stats["primary_performance"] == "confused"
      assert stats["rotation_error"] == nil
    end

    test "scores the object it was standing on separately" do
      stats =
        lm(
          stepwise_target_object: "bowl",
          graph_id_to_target: %{"mug_graph" => MapSet.new(["mug"])}
        )
        |> LoggingUtils.graph_lm_episode_stats()

      assert stats["primary_performance"] == "correct"
      assert stats["stepwise_performance"] == "confused"
    end
  end

  describe "the endings that are not a recognition" do
    test "no hypothesis left is a no-match" do
      stats = LoggingUtils.graph_lm_episode_stats(lm(possible_matches: []))

      assert stats["primary_performance"] == "no_match"
      assert stats["num_possible_matches"] == 0
    end

    test "an object with no label cannot be scored" do
      stats = LoggingUtils.graph_lm_episode_stats(lm(primary_target: "no_label"))

      assert stats["primary_performance"] == "no_label"
    end

    test "a timeout with one hypothesis left is a pose that is not settled" do
      stats = LoggingUtils.graph_lm_episode_stats(lm(terminal_state: "time_out"))

      assert stats["primary_performance"] == "pose_time_out"
      assert stats["result"] == ["mug_graph"]
    end

    test "a timeout with several hypotheses left stays a timeout" do
      stats =
        LoggingUtils.graph_lm_episode_stats(
          lm(terminal_state: "time_out", possible_matches: ["mug_graph", "bowl_graph"])
        )

      assert stats["primary_performance"] == "time_out"
    end
  end

  describe "the individual terminal state" do
    test "is scored on its own, when the module reached one before the end" do
      stats =
        lm(
          buffer:
            buffer(%{
              "detected_rotation_quat" => @identity_xyzw,
              "time" => [1],
              "individual_ts_reached_at_step" => 4,
              "individual_ts_object" => "mug_graph",
              "individual_ts_rot" => @identity_xyzw
            })
        )
        |> LoggingUtils.graph_lm_episode_stats()

      assert stats["individual_ts_reached_at_step"] == 4
      assert stats["individual_ts_performance"] == "correct"
      assert stats["individual_ts_rotation_error"] == 0.0
    end

    test "is a no-match when the module reached a state without an object" do
      stats =
        lm(
          buffer:
            buffer(%{
              "detected_rotation_quat" => @identity_xyzw,
              "time" => [1],
              "individual_ts_reached_at_step" => 4,
              "individual_ts_object" => nil
            })
        )
        |> LoggingUtils.graph_lm_episode_stats()

      assert stats["individual_ts_performance"] == "no_match"
      assert stats["individual_ts_rotation_error"] == nil
    end
  end

  describe "what the possible matches were built from" do
    test "says the target was among them when it was" do
      stats = LoggingUtils.graph_lm_episode_stats(lm())

      assert stats["TFNP"] == "target_in_possible_matches_(TP)"
      assert stats["possible_match_sources"] == "mug"
      assert stats["mean_objects_per_graph"] == 1.0
      assert stats["mean_graphs_per_object"] == 1.0
    end

    test "says the target was never matched when nothing stood for it" do
      stats =
        lm(
          graph_id_to_target: %{"mug_graph" => MapSet.new(["bowl"])},
          target_to_graph_id: %{"bowl" => MapSet.new(["mug_graph"])}
        )
        |> LoggingUtils.graph_lm_episode_stats()

      assert stats["TFNP"] == "unknown_object_in_possible_matches_(FP)"
    end

    test "says an object it was never trained on was not recognised" do
      stats =
        lm(
          graph_id_to_target: %{"mug_graph" => MapSet.new(["bowl"])},
          target_to_graph_id: %{"bowl" => MapSet.new(["mug_graph"])},
          possible_matches: []
        )
        |> LoggingUtils.graph_lm_episode_stats()

      assert stats["TFNP"] == "unknown_object_not_matched_(TN)"
      assert stats["possible_match_sources"] == ""
    end
  end

  describe "the episode's rows" do
    test "are keyed by module position, and carry the run's counts and the target" do
      target = %{"object" => "mug", "position" => [0.1, 0.0, 0.0], "scale" => [1.0]}

      rows =
        LoggingUtils.stats_per_lm([lm(), lm()], target,
          step: 12,
          matching_steps: 9,
          episode_seed: 7
        )

      assert Map.keys(rows) == ["LM_0", "LM_1"]

      assert %{
               "primary_performance" => "correct",
               "monty_steps" => 12,
               "monty_matching_steps" => 9,
               "episode_seed" => 7,
               "primary_target_object" => "mug",
               "stepwise_target_object" => nil
             } = rows["LM_0"]
    end
  end
end
