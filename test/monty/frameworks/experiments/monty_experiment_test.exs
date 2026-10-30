defmodule Monty.Frameworks.Experiments.MontyExperimentTest do
  @moduledoc """
  Monty's episode loop, over a step that is not a model.

  The state is a counter and the report is the count, so what the tests can say
  is what the loop is answerable for: when it stops, how many steps the episode
  took, and what a step that could not be taken becomes.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Experiments.MontyExperiment

  defp episode(options \\ []) do
    Map.merge(
      %{
        step: fn count -> {:ok, count + 1, count + 1} end,
        finished?: fn count -> count >= 3 end,
        stopped?: fn -> false end
      },
      Map.new(options)
    )
  end

  test "steps until the experiment's policy says the episode is over" do
    assert {:finished, [3, 2, 1], 3} = MontyExperiment.run_episode_steps(0, episode())
  end

  test "a stop lands between steps, not inside one" do
    assert {:stopped, [], 0} =
             MontyExperiment.run_episode_steps(0, episode(stopped?: fn -> true end))
  end

  test "a step that could not be taken ends the episode with the steps that were" do
    dies_after_two = %{
      episode()
      | step: fn
          count when count < 2 -> {:ok, count + 1, count + 1}
          _count -> {:error, :module_died}
        end
    }

    assert {{:crashed, 2, :module_died}, [2, 1], 2} =
             MontyExperiment.run_episode_steps(0, dies_after_two)
  end

  test "an episode that finishes on its first step takes one step" do
    assert {:finished, [1], 1} =
             MontyExperiment.run_episode_steps(0, episode(finished?: fn count -> count >= 1 end))
  end
end
