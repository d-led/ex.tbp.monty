defmodule Monty.Studio.Summary.RestoreTest do
  @moduledoc """
  A summary as a record keeps it, read back so a run that continues can add to
  it.

  The record's spelling is a page's (`RunLog.summary/2`), the live fold's is the
  model's, and a resumed run is the one place the two are added together.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Summary

  @stored %{
    "steps" => 40,
    "duration_us" => 1_000,
    "world_us" => 500,
    "deadline_hits" => 0,
    "goals" => 3,
    "votes_sent" => 12,
    "votes_used" => 11,
    "actions" => 9,
    "inputs" => %{"learning_module_0" => 34_676},
    "never_updated" => [],
    "sensor_timeouts" => ["patch"],
    "outcome" => %{"learning_module_0" => "match"},
    "outcomes" => %{"learning_module_0" => %{"match" => 2, "time_out" => 1}}
  }

  test "reads back the numbers the run had reached" do
    restored = Summary.restore(@stored)

    assert {restored.steps, restored.duration_us, restored.goals, restored.votes_sent} ==
             {40, 1_000, 3, 12}

    assert restored.inputs == %{"learning_module_0" => 34_676}
  end

  # The one thing a summary cannot get wrong on a resume: a restored tally and a
  # live one are added under the same key per conclusion, or a page shows one
  # module twice.
  test "reads the conclusions back as the fold counts them" do
    restored = Summary.restore(@stored)

    assert restored.outcome == %{"learning_module_0" => :match}
    assert restored.sensor_timeouts == [:patch]

    assert restored.outcomes == %{"learning_module_0" => %{match: 2, time_out: 1}}

    assert %{outcomes: %{"learning_module_0" => %{match: 3, time_out: 1}}} =
             Summary.merge(
               restored,
               Summary.restore(%{"outcomes" => %{"learning_module_0" => %{"match" => 1}}})
             )
  end

  test "a record that has added nothing up yet reads as nothing" do
    assert Summary.restore(nil) == %Summary{}
    assert Summary.restore(%{}) == %Summary{}
  end

  # A record carries why a run stopped, which is not an amount of anything.
  test "what is not a number of the run is left out" do
    restored = Summary.restore(%{"reason" => "it stopped", "technical" => nil, "steps" => 7})

    assert restored.steps == 7
  end
end
