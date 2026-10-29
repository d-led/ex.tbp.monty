defmodule Monty.PretrainedReplayTest do
  @moduledoc """
  Monty's own pretrained object library, matched by the Elixir learning module.

  `test/fixtures/monty_pretrained_episode.jsonl` is one episode of Monty's
  `surf_agent_1lm_10distinctobj` recorded while it ran, and
  `priv/monty/libraries/surf_agent_1lm_10distinctobj.jsonl.gz` is the memory that
  experiment matched against, exported from Monty's own torch pickle. Replaying
  the one through the other is the only check that says whether the port adds up
  the same numbers, as opposed to reaching the same conclusion by another route.

  ## What agrees, and to how much

  The first observation agrees to about `5e-7` on every object — that is the
  export's rounding, and it is where the arithmetic of scoring, displacement and
  the pose comparison is pinned. Hypotheses agree exactly while nothing is being
  pruned, and to within a couple of hypotheses once evidence slopes decide what
  survives: a slope is a difference of two nearly equal numbers, so the last
  digits of the evidence decide which hypotheses live. Evidence then drifts by
  about a thousandth over a hundred steps, and by more for objects that are
  being pruned away — the same cause, amplified.

  So the assertions here are: exact agreement on the first observation, counts
  that never disagree by more than a couple, evidence that tracks Monty's to a
  thousandth, and the conclusion Monty reached.
  """

  use ExUnit.Case, async: true

  # Loading the exported library and replaying a hundred steps of Monty's own
  # episode is minutes of work on a cold runner, not the one minute ExUnit
  # allows by default.
  @moduletag timeout: 300_000

  alias Monty.Context
  alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Test.MontyRecording

  @recording "test/fixtures/monty_pretrained_episode.jsonl"
  @pretrained "priv/monty/libraries/surf_agent_1lm_10distinctobj.jsonl.gz"

  # The tolerances and weights of the experiment the recording came from
  # (`learning_module/evidence_1lm_nn5_dod0025.yaml`), and its burst sampler.
  defp learning_module do
    {:ok, lm} =
      EvidenceGraphLM.new(MontyRecording.load_pretrained!(@pretrained),
        max_match_distance: 0.01,
        max_nneighbors: 5,
        hypotheses_updater: BurstSamplingHypothesesUpdater,
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

  # Every step, with what Monty held after it: one entry per recorded step, and
  # `nil`-free from there on for the steps Monty's module was given nothing.
  #
  # A step keeps the two projections below — a handful of numbers each — and not
  # the learning module itself. A module holds every hypothesis of every object,
  # and an episode is a hundred and ten of them: keeping them all costs three
  # and a half gigabytes of snapshots for numbers that fit on a page, which is
  # what made this module the peak of the suite.
  defp replay do
    steps = MontyRecording.load!(@recording)
    monty = MontyRecording.evidence_over_steps!(@recording)
    counts = MontyRecording.hypothesis_counts!(@recording)

    {seen, last} =
      Enum.reduce(steps, {[], learning_module()}, fn
        [], {seen, lm} ->
          {[nil | seen], lm}

        percepts, {seen, lm} ->
          {:ok, lm} = EvidenceGraphLM.matching_step(percepts, Context.new(0), lm)
          lm = EvidenceGraphLM.add_lm_processing_to_buffer_stats(lm, true)
          {lm, _terminal_state} = EvidenceGraphLM.update_terminal_condition(lm)
          {[observation(lm) | seen], lm}
      end)

    %{
      steps: seen |> Enum.reverse() |> with_monty(monty, counts),
      conclusion: %{
        terminal_state: last.terminal_state,
        detected_object: last.detected_object
      }
    }
  end

  defp observation(lm), do: %{evidence: evidence(lm), hypotheses: hypotheses(lm)}

  defp evidence(lm) do
    {ids, evidences} = EvidenceGraphLM.evidence_for_each_graph(lm)
    Map.new(Enum.zip(ids, evidences))
  end

  defp hypotheses(lm),
    do: Map.new(lm.hypotheses, fn {id, hypotheses} -> {id, length(hypotheses.evidence)} end)

  defp steps_with_evidence(replay), do: replay.steps

  defp with_monty(observations, monty, counts) do
    observations
    |> Enum.with_index()
    |> Enum.reject(fn {observation, _index} -> is_nil(observation) end)
    |> Enum.map(fn {observation, index} ->
      Map.merge(observation, %{
        index: index,
        monty: Enum.at(monty, index),
        counts: Enum.at(counts, index)
      })
    end)
  end

  setup_all do
    %{replay: replay()}
  end

  describe "matching against Monty's pretrained memory" do
    test "the first observation's evidence is Monty's on every object", %{replay: replay} do
      first = hd(steps_with_evidence(replay))

      assert Map.keys(first.evidence) |> Enum.sort() == first.monty |> Map.keys() |> Enum.sort()

      for {object_id, theirs} <- first.monty do
        assert_in_delta first.evidence[object_id], theirs, 1.0e-6, "#{object_id} evidence"
      end
    end

    test "the hypothesis space stays Monty's, object by object", %{replay: replay} do
      for step <- steps_with_evidence(replay),
          {object_id, theirs} <- step.counts,
          Map.has_key?(step.hypotheses, object_id) do
        # While nothing is pruned the two agree exactly. Once evidence slopes
        # decide what survives, a slope is a difference of two nearly equal
        # numbers, so the last digits of the evidence can keep or lose a
        # hypothesis or two — never a different order of magnitude.
        tolerance = max(2, div(theirs, 100))
        ours = step.hypotheses[object_id]

        assert abs(ours - theirs) <= tolerance,
               "step #{step.index}: #{object_id} has #{ours}, Monty #{theirs}"
      end
    end

    test "evidence for the object it settles on tracks Monty's all episode", %{replay: replay} do
      # The episode concludes on the mug, and the mug's evidence is the number
      # the conclusion is drawn from: it stays within a thousandth of Monty's
      # for all hundred and ten steps. Objects whose hypotheses are being pruned
      # wander further, because losing a hypothesis is decided by comparing
      # slopes of nearly equal evidence, and that is where two implementations
      # can part company without either being wrong.
      for step <- steps_with_evidence(replay), Map.has_key?(step.monty, "mug") do
        assert_in_delta step.evidence["mug"],
                        step.monty["mug"],
                        2.0e-3,
                        "step #{step.index}: mug evidence"
      end
    end

    test "the episode ends where Monty's ended", %{replay: replay} do
      monty = MontyRecording.final_state!(@recording)

      assert monty["terminal_state"] == "match"
      assert replay.conclusion.terminal_state == :match

      assert monty["detected_object"] == "mug"
      assert replay.conclusion.detected_object == "mug"
    end
  end
end
