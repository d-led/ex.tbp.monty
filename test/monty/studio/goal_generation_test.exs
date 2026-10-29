defmodule Monty.Studio.GoalGenerationTest do
  @moduledoc """
  The goal generator a run actually drives, and why it asks for nothing yet.

  A learning module only asks to look somewhere else when it has something to be
  uncertain about: two objects it cannot separate, or one object whose pose is
  still open. An episode against an empty long-term memory has neither — it has
  no hypotheses at all — so a first episode proposes no goal, and that is
  Monty's behaviour rather than a missing feature.

  These tests pin both halves: the generator reaches the running module, and the
  reason it stays quiet is the module's empty memory, not a broken wire. When the
  port can train over a corpus (or run against a world with more than one object)
  this is where a non-empty goal will be specified.
  """

  use ExUnit.Case, async: false

  alias Monty.Frameworks.Models.GoalGeneration.EvidenceGoalGenerator
  alias Monty.Runtime.{LearningModuleServer, Registry}
  alias Monty.Studio.Run

  @experiment "base_10simobj_surf_agent"
  @learning_module "learning_module_0"

  defp start do
    {:ok, opened} = Monty.Studio.open(@experiment)
    {:ok, run} = Run.start(opened.setup, steps: 20)

    {run, Registry.via({:learning_module, run.model_id, @learning_module})}
  end

  defp learning_module(lm), do: LearningModuleServer.state(lm)

  # The reports the run's steps answered with, oldest first.
  defp step(run, times) do
    Enum.reduce(1..times, {run, []}, fn _step, {run, infos} ->
      {:ok, info, _observations, run} = Run.step(run)
      {run, [info | infos]}
    end)
    |> then(fn {run, infos} -> {run, Enum.reverse(infos)} end)
  end

  test "the module is handed its experiment's generator, pointed at itself" do
    {run, lm} = start()

    try do
      {_run, _infos} = step(run, 1)

      # `point_at` is what Monty does on reset: a generator without its module
      # cannot read hypotheses, and would be a generator that never fires.
      state = learning_module(lm)
      assert %EvidenceGoalGenerator{} = state.gsg

      # The same module, not merely a module of the same shape.
      assert EvidenceGoalGenerator.parent_lm(state.gsg).learning_module_id ==
               state.learning_module_id
    after
      Run.stop(run)
    end
  end

  test "and it proposes no goal, because an episode with no memory has nothing to separate" do
    {run, lm} = start()

    try do
      {_run, infos} = step(run, 20)

      assert Enum.map(infos, & &1.goals) == List.duplicate(0, 20)
      assert learning_module(lm).possible_matches == []
    after
      Run.stop(run)
    end
  end
end
