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
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Frameworks.Models.ObjectModel.GraphObjectModel
  alias Monty.Frameworks.Models.NoResetEvidenceMatching.NoResetEvidenceGraphLM
  alias Monty.Frameworks.Utils.LoggingUtils
  alias Monty.Geometry.Rotation

  # A detected rotation is scipy's `xyzw`; the pose the object was placed with
  # travels scalar-first, Monty's `Rotation.as_quat` — the two conventions the
  # stats have to keep apart.
  @identity_xyzw [0.0, 0.0, 0.0, 1.0]
  @identity_wxyz [1.0, 0.0, 0.0, 0.0]

  defp quarter_turn do
    {:ok, rotation} = Rotation.from_euler_degrees([0.0, 90.0, 0.0])
    rotation
  end

  defp as_wxyz(rotation), do: rotation |> Rotation.to_quaternion() |> Tuple.to_list()
  defp as_xyzw(rotation), do: Rotation.to_xyzw(rotation)

  # One hypothesis, which is what a recognition is narrowed to: the module
  # believes it is standing at the object's place, and the statistics say so.
  defp one_hypothesis(graph_id, evidence) do
    %{
      graph_id =>
        Hypotheses.new(
          evidence: [evidence],
          locations: [[0.1, 0.0, 0.0]],
          poses: [Rotation.to_matrix(Rotation.identity())],
          possible: [true]
        )
    }
  end

  # A memory that knows `graph_ids`, because the module's best hypothesis is
  # asked of the memory as well as of the hypothesis spaces — a real module's
  # two agree, and a fixture where they do not is a module no episode produced.
  defp memory_with(graph_ids) do
    graph_ids
    |> Enum.reduce(GraphMemory.new(features_to_use: %{"patch" => ["hsv"]}), fn id, memory ->
      model =
        id
        |> GraphObjectModel.new()
        |> GraphObjectModel.build_model(
          [[0.0, 0.0, 0.0]],
          %{"hsv" => [[0.0, 0.0, 0.0]]},
          nil,
          nil
        )

      GraphMemory.add_graph_to_memory(memory, %{"patch" => model}, id)
    end)
    |> GraphMemory.initialize_feature_arrays()
  end

  # What the episode did to this module: on the object, what it concluded, and
  # which objects the graph it matched was built from.
  defp lm(overrides \\ []) do
    found =
      %{
        graph_id_to_target: %{"mug_graph" => MapSet.new(["mug"])},
        target_to_graph_id: %{"mug" => MapSet.new(["mug_graph"])},
        primary_target: "mug",
        primary_target_rotation_quat: @identity_wxyz,
        terminal_state: :match,
        detected_object: "mug_graph",
        detected_pose: [0.1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0],
        possible_matches: ["mug_graph"],
        symmetry_evidence: 2,
        # An evidence module always holds a memory and a hypothesis space; the
        # statistics read the best hypothesis of both, so a module without them
        # is a module no episode produced.
        graph_memory: memory_with(["mug_graph"]),
        hypotheses: one_hypothesis("mug_graph", 7.5),
        current_mlh: %{
          graph_id: "mug_graph",
          mlh_id: 0,
          location: [0.1, 0.0, 0.0],
          rotation: Rotation.identity(),
          scale: 1,
          evidence: 7.5
        },
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
          primary_target_rotation_quat: as_wxyz(quarter_turn()),
          buffer: buffer(%{"detected_rotation_quat" => @identity_xyzw, "time" => [1, 3]})
        )
        |> LoggingUtils.graph_lm_episode_stats()

      assert stats["primary_performance"] == "correct"
      # The stepwise judgement is about the object it stood on, which nothing
      # recorded here — Monty's own reading, and the case with one is next.
      assert stats["stepwise_performance"] == "confused"
      # The object was placed a quarter turn from the pose the module reported.
      assert stats["rotation_error"] == 90.0
      assert stats["result"] == "mug_graph"
    end

    test "the pose it reported as the object's is no rotation error at all" do
      stats =
        lm(
          primary_target_rotation_quat: as_wxyz(quarter_turn()),
          buffer: buffer(%{"detected_rotation_quat" => as_xyzw(quarter_turn()), "time" => [1, 3]})
        )
        |> LoggingUtils.graph_lm_episode_stats()

      assert stats["rotation_error"] == 0.0
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

    test "a timeout is judged on the object it was still holding, not on the timeout" do
      stats = LoggingUtils.graph_lm_episode_stats(lm(terminal_state: :time_out))

      # Monty's `calculate_performance` (logging_utils.py:816-835): the episode ran
      # out of steps while its best hypothesis was the object it was asked about.
      assert stats["primary_performance"] == "correct_mlh"
      assert stats["result"] == ["mug_graph"]
    end

    test "a timeout holding another object is confused, however many it still had" do
      stats =
        LoggingUtils.graph_lm_episode_stats(
          lm(
            terminal_state: :time_out,
            possible_matches: ["mug_graph", "bowl_graph"],
            current_mlh: %{
              graph_id: "bowl_graph",
              mlh_id: 0,
              location: [0.1, 0.0, 0.0],
              rotation: Rotation.identity(),
              scale: 1,
              evidence: 3.0
            },
            hypotheses: one_hypothesis("bowl_graph", 3.0),
            graph_memory: memory_with(["bowl_graph"])
          )
        )

      assert stats["primary_performance"] == "confused_mlh"
    end
  end

  describe "the hypothesis the module believed most" do
    # Monty's `add_evidence_lm_episode_stats` (logging_utils.py:787-803): the
    # best hypothesis's object, location, rotation and evidence, and the mean
    # prediction error of the episode. No unit test of its own upstream, so
    # these state the function's behaviour rather than translating a case.
    test "is written as the evidence and the pose a reader compares episodes by" do
      stats = LoggingUtils.graph_lm_episode_stats(lm())

      assert stats["most_likely_object"] == "mug_graph"
      assert stats["highest_evidence"] == 7.5
      assert stats["most_likely_location"] == [0.1, 0.0, 0.0]
      assert stats["most_likely_rotation"] == [0.0, 0.0, 0.0]
    end

    test "a module that saw nothing has no evidence to report, not an invented one" do
      stats =
        LoggingUtils.graph_lm_episode_stats(
          lm(graph_memory: GraphMemory.new(), hypotheses: %{}, current_mlh: nil)
        )

      assert stats["most_likely_object"] == "new_object0"
      assert stats["highest_evidence"] == 0
    end

    test "counts the goals the policy set, and the ones it reached" do
      stats =
        LoggingUtils.graph_lm_episode_stats(
          lm(
            buffer:
              buffer(%{
                "detected_rotation_quat" => @identity_xyzw,
                "time" => [1, 3],
                "goal_state_achieved" => [true, false, true]
              })
          )
        )

      assert stats["goal_states_attempted"] == 3
      assert stats["goal_state_achieved"] == 2
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

  describe "a module that composes another" do
    # Monty's no-reset module is an `EvidenceGraphLM` by inheritance and by
    # composition here, so an episode's statistics are the composed module's.
    # Reading them off the wrapper is what crashed a studio run at the end of
    # every episode: `key :buffer not found`.
    test "reports the statistics of the module it composes" do
      inner = lm(stepwise_target_object: "bowl")

      assert LoggingUtils.graph_lm_episode_stats(NoResetEvidenceGraphLM.new(inner)) ==
               LoggingUtils.graph_lm_episode_stats(inner)
    end

    test "answers the episode's row as that module's row" do
      inner = lm()

      rows =
        LoggingUtils.stats_per_lm([NoResetEvidenceGraphLM.new(inner)], %{"object_name" => "mug"},
          step: 12,
          matching_steps: 9
        )

      assert %{"primary_performance" => "correct", "num_steps" => _} = rows["LM_0"]
    end
  end

  describe "the episode's rows" do
    test "are keyed by module position, and carry the run's counts and the target" do
      target = %{"object_name" => "mug", "position" => [0.1, 0.0, 0.0], "scale" => [1.0]}

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
