defmodule Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLMParallelTest do
  @moduledoc """
  A step's per-object evidence updates, in a round and one at a time.

  Monty runs one thread per object (`use_multithreading`, on by default) because
  the objects share nothing. The port's round is the same one, with
  `merge_step/2` putting the updater back together afterwards — and a round is
  only worth its processes if it answers exactly what the loop answers, so both
  are run here over one memory and one sequence of observations and compared as
  numbers after every step.

  What is compared is everything the step decided: each object's whole
  hypothesis space, the objects still possible, the module's most likely
  hypothesis, the per-object telemetry and the updater's own memory — because a
  merge that dropped one object's slope trackers would leave the answers looking
  right for a step or two.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater
  alias Monty.Frameworks.Models.EvidenceMatching.GraphMemory.EvidenceGraphMemory
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater
  alias Monty.Frameworks.Models.EvidenceMatching.HypothesesUpdater.DefaultHypothesesUpdater
  alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
  alias Monty.Frameworks.Models.GraphMatching.GraphMemory
  alias Monty.Geometry.Rotation
  alias Monty.Test.Messages

  @channel "patch"
  @pose [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]

  @mug_locations [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0], [0.01, 0.01, 0.0]]
  @bowl_locations [[0.0, 0.0, 0.0], [0.01, 0.0, 0.0], [0.01, 0.01, 0.0]]

  # Curvature is the only feature that differs between the two objects, so a
  # percept earns evidence for both graphs and the round has more than one object
  # to be wrong about.
  @curvature %{"mug" => [0.0, 0.5], "bowl" => [1.0, 1.5]}

  # Three places, each on a stored node, with one object's curvature and then the
  # other's: the evidence has to move differently per object for a round to be
  # interesting.
  defp percepts do
    for {object, locations} <- [mug: @mug_locations, bowl: @bowl_locations],
        location <- locations do
      Messages.percept(%{
        location: location,
        sender_id: @channel,
        non_morphological_features: %{
          "principal_curvatures_log" => Map.fetch!(@curvature, Atom.to_string(object))
        }
      })
    end
  end

  describe "a round of per-object updates" do
    setup do
      %{memory: memory()}
    end

    test "answers, step by step, what one update at a time answers", %{memory: memory} do
      walk(memory, DefaultHypothesesUpdater)
    end

    test "answers the same with an updater that remembers each object's slope", %{
      memory: memory
    } do
      # The burst updater keeps a tracker a graph, which is the state a merge
      # could silently halve: a round that dropped one object's history would
      # still look right until that object's evidence stalled.
      walk(memory, BurstSamplingHypothesesUpdater)
    end

    # The same observations through both paths, compared after every step: a
    # difference is reported at the step that made it, not at the end of the walk.
    defp walk(memory, updater) do
      {round, one_at_a_time} =
        {module(memory, updater, true), module(memory, updater, false)}

      Enum.reduce(percepts(), {round, one_at_a_time}, fn percept, {round, one_at_a_time} ->
        round = step(round, percept)
        one_at_a_time = step(one_at_a_time, percept)

        assert beliefs(round) == beliefs(one_at_a_time)

        {round, one_at_a_time}
      end)
    end

    # Two objects with a space each is what makes the comparison worth making: a
    # round that dropped an object would be comparing one graph against one.
    test "the fixture gives both objects a hypothesis space", %{memory: memory} do
      lm =
        Enum.reduce(percepts(), module(memory, DefaultHypothesesUpdater, true), &step(&2, &1))

      assert Enum.sort(Map.keys(lm.hypotheses)) == ["bowl", "mug"]
      assert Enum.all?(Map.values(lm.hypotheses), &(Hypotheses.count(&1) > 0))
    end

    # Monty's threads share the memory and its `use_multithreading` is all it
    # needs. A BEAM task is handed a copy of what its closure holds, so the round
    # needs a memory other processes can hold without copying it *and* a run that
    # asks: measured, the round is equal on a big memory and about 4 % more work
    # on the five-module episode (`docs/monty-differences.md` §2.45).
    test "a round is taken only when the config, the memory and the run all ask", %{
      memory: memory
    } do
      shared = module(memory, DefaultHypothesesUpdater, true)

      assert EvidenceGraphLM.graph_round?(shared)
      refute EvidenceGraphLM.graph_round?(%{shared | memory_shared?: false})
      refute EvidenceGraphLM.graph_round?(%{shared | use_multithreading: false})
      refute EvidenceGraphLM.graph_round?(%{shared | round_objects?: false})
    end
  end

  defp step(lm, percept), do: EvidenceGraphLM.compute_possible_matches(lm, [percept], false)

  # The rule a round's merge is built on, on its own: two halves of one state,
  # each having changed some of its keys relative to what they started from.
  describe "putting two halves of a step back together" do
    @base %{"bowl" => 1, "mug" => 2, "spoon" => 3}
    @bowl_updated %{"bowl" => 10, "mug" => 2, "spoon" => 3}
    @mug_updated %{"bowl" => 1, "mug" => 20, "spoon" => 3}

    # Both halves carry the base's copy of the graph the other one updated, so a
    # merge of whole maps would answer `bowl => 1` — the stale copy — and lose
    # the update that had just been made.
    test "changes from both halves are kept, and neither half's stale copy wins" do
      assert HypothesesUpdater.merge_changed(@base, @bowl_updated, @mug_updated) ==
               %{"bowl" => 10, "mug" => 20, "spoon" => 3}
    end

    test "a key neither half touched keeps what it had" do
      assert HypothesesUpdater.merge_changed(@base, @base, @mug_updated) ==
               %{"bowl" => 1, "mug" => 20, "spoon" => 3}
    end

    test "the order the halves arrive in does not matter" do
      assert HypothesesUpdater.merge_changed(@base, @bowl_updated, @mug_updated) ==
               HypothesesUpdater.merge_changed(@base, @mug_updated, @bowl_updated)
    end
  end

  # Everything a step decided, so a difference anywhere is a failure here.
  defp beliefs(lm) do
    %{
      hypotheses: lm.hypotheses,
      possible_matches: lm.possible_matches,
      mlh: lm.current_mlh,
      telemetry: lm.hypotheses_updater_telemetry,
      updater: lm.hypotheses_updater
    }
  end

  # One memory for both paths: they answer questions about the same objects, and a
  # memory holds its index as a native reference, so two separately built memories
  # would differ by identity in the very state being compared.
  defp module(memory, updater, use_multithreading) do
    {:ok, lm} =
      EvidenceGraphLM.new(memory,
        max_match_distance: 0.01,
        tolerances: %{@channel => %{"principal_curvatures_log" => [1.0, 1.0]}},
        hypotheses_updater: updater,
        use_multithreading: use_multithreading,
        # The fixture's memory is small enough to be held by a task whatever it
        # is; the flag stands for the studio's cached library, which is the case
        # the round exists for.
        memory_shared?: true,
        round_objects?: true
      )

    lm
  end

  defp memory do
    %{"mug" => @mug_locations, "bowl" => @bowl_locations}
    |> Enum.reduce(EvidenceGraphMemory.new(max_graph_size: 0.3), fn {object, locations}, memory ->
      GraphMemory.update_memory(
        memory,
        locations,
        %{
          @channel => %{
            "principal_curvatures_log" =>
              List.duplicate(Map.fetch!(@curvature, object), length(locations)),
            "pose_vectors" => List.duplicate(@pose, length(locations)),
            "pose_fully_defined" => List.duplicate(true, length(locations))
          }
        },
        object,
        [0.0, 0.0, 0.0],
        [0.0, 0.0, 0.0],
        Rotation.identity()
      )
    end)
  end
end
