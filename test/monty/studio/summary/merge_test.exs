defmodule Monty.Studio.Summary.MergeTest do
  @moduledoc """
  Two summaries added, which is what a run of several parts is.

  A parallel run is one experiment in four processes, and the page that shows
  four parts' steps shows one number: what a part counted is added up, and what
  each part's modules concluded is one tally.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.{Setup, Summary}

  test "what each part counted is added up" do
    one = %Summary{steps: 3, duration_us: 30, world_us: 300, goals: 2, actions: 4}
    other = %Summary{steps: 5, duration_us: 50, world_us: 500, goals: 1, actions: 6}

    merged = Summary.merge(one, other)

    assert %Summary{steps: 8, duration_us: 80, world_us: 800, goals: 3, actions: 10} = merged
  end

  test "the modules either part fed are the ones fed" do
    one = %Summary{inputs: %{"learning_module_0" => 4}}
    other = %Summary{inputs: %{"learning_module_0" => 2, "learning_module_1" => 7}}

    assert Summary.merge(one, other).inputs == %{
             "learning_module_0" => 6,
             "learning_module_1" => 7
           }
  end

  test "two parts' episodes are one tally" do
    one = %Summary{outcomes: Summary.tally(%{}, %{"lm_0" => :match})}
    other = %Summary{outcomes: Summary.tally(%{}, %{"lm_0" => :time_out})}

    merged = Summary.merge(one, other)

    assert merged.outcomes == %{"lm_0" => %{match: 1, time_out: 1}}
    assert Summary.outcomes_line(merged.outcomes) == "lm_0: match 1, time_out 1 of 2"
  end

  # The point of merging rather than taking one part's: a module neither part
  # fed is the one failure that looks like success, and `finish/4` says so from
  # the counts this added up.
  test "a module neither part fed is still named as never having been fed" do
    setup = %Setup{learning_modules: [%{id: "learning_module_0"}, %{id: "learning_module_1"}]}

    one = %Summary{inputs: %{"learning_module_0" => 9}}
    other = %Summary{inputs: %{"learning_module_0" => 3}}

    finished = Summary.finish(Summary.merge(one, other), setup, %{})

    assert finished.never_updated == ["learning_module_1"]
  end

  test "a part's last step is not the run's, so the merge does not claim one" do
    assert Summary.merge(%Summary{outcome: %{"lm_0" => :match}}, %Summary{}).outcome == %{}
  end
end
