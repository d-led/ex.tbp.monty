defmodule Monty.ReplayTest do
  @moduledoc """
  The Elixir learning module, fed the observations Monty was fed.

  `test/fixtures/monty_10distinctobj_episode.jsonl` is one episode of Monty's
  own `base_config_10distinctobj_surf_agent`, recorded from Monty while it ran:
  twenty-one steps of a surface agent walking a YCB object, each step carrying
  the HSV colour, the log curvature and the surface pose vectors Monty's module
  saw, and what Monty's module concluded from them.

  This episode ran with nothing in memory, so Monty's answer is `no_match` and a
  new object. Ours has to say the same — and, more usefully, has to get there
  without tripping over a feature it did not expect, which is what a recording
  of real observations is for.
  """

  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Test.MontyRecording

  @recording "test/fixtures/monty_10distinctobj_episode.jsonl"

  # The tolerances and weights of the experiment the recording came from
  # (`learning_module/evidence_1lm_nn5_dod0025.yaml`).
  defp learning_module do
    {:ok, lm} =
      EvidenceGraphLM.new(GraphMemory.new(),
        max_match_distance: 0.01,
        tolerances: %{
          "patch" => %{"hsv" => [0.1, 0.2, 0.2], "principal_curvatures_log" => [1.0, 1.0]}
        },
        feature_weights: %{
          "patch" => %{
            "hsv" => [2.0, 0.5, 0.5],
            "pose_vectors" => [1.0, 1.0, 1.0],
            "principal_curvatures_log" => [1.0, 1.0]
          }
        },
        x_percent_threshold: 20,
        evidence_threshold_config: "all"
      )

    lm
  end

  defp replay(lm, steps) do
    Enum.reduce(steps, lm, fn percepts, lm ->
      {:ok, lm} = EvidenceGraphLM.matching_step(percepts, Context.new(0), lm)
      lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, true)
      {lm, _terminal_state} = EvidenceGraphLM.update_terminal_condition(lm)
      lm
    end)
  end

  describe "an episode of Monty's own experiment" do
    test "the recording carries the observations a module matches on" do
      steps = MontyRecording.load!(@recording)

      assert length(steps) == 21

      for [percept] <- steps do
        assert percept.sender_id == "patch"
        assert percept.sender_type == :sm
        assert [_, _, _] = percept.location

        assert %Monty.Geometry.SurfacePoseVectors{value: [_, _, _]} =
                 percept.morphological_features["pose_vectors"]

        assert is_boolean(percept.morphological_features["pose_fully_defined"])
        assert [_h, _s, _v] = percept.non_morphological_features["hsv"]
      end
    end

    test "our module concludes what Monty's concluded, from the same observations" do
      monty = MontyRecording.final_state!(@recording)

      lm = replay(learning_module(), MontyRecording.load!(@recording))

      assert monty["terminal_state"] == "no_match"
      assert lm.terminal_state == :no_match

      assert monty["detected_object"] == "new_object0"
      assert lm.detected_object == "new_object0"

      assert monty["possible_matches"] == []
      assert EvidenceGraphLM.get_possible_matches(lm) == []
    end

    test "every observation was buffered, and every one was counted as processed" do
      lm = replay(learning_module(), MontyRecording.load!(@recording))

      assert Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer.get_num_observations_on_object(
               lm.buffer
             ) == 21

      assert Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer.get_num_matching_steps(
               lm.buffer
             ) ==
               21
    end
  end
end
