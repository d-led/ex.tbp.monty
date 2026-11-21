defmodule Monty.Studio.StepShapeTest do
  @moduledoc """
  The sentence beside a log says what the log's numbers measured.

  A step's phases are the wall clock of a round, so the same number means two
  different things depending on how the run was shaped. These hold the words to
  the shape: nothing to say about Monty's own order, and the one sentence that
  explains each way a run can be faster without being slower.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.StepShape

  @five_sensors ~w(vf patch_0 patch_1 patch_2 patch_3)

  test "says nothing about a run there is nothing to explain about" do
    assert StepShape.sentences(%{
             "sensors_step" => "serial",
             "scheduling" => "barrier",
             "sensors" => ["patch_0"]
           }) == []
  end

  # One sensor is a round of one: there is no difference between "at the same
  # time" and "one after another" to explain.
  test "says nothing about a single sensor, whichever way it is served" do
    assert StepShape.sentences(%{"sensors_step" => "concurrent", "sensors" => ["patch_0"]}) ==
             []
  end

  test "says a concurrent round costs its slowest sensor" do
    assert [sentence] =
             StepShape.sentences(%{"sensors_step" => "concurrent", "sensors" => @five_sensors})

    assert sentence =~ "at the same time"
    assert sentence =~ "slowest of them, not their sum"
  end

  test "says a serial round costs the sum" do
    assert [sentence] =
             StepShape.sentences(%{"sensors_step" => "serial", "sensors" => @five_sensors})

    assert sentence =~ "one after another"
    assert sentence =~ "their sum"
  end

  # The deployment's rule is not a choice, so it is stated as the rule it is: a
  # run that recorded nothing chose nothing, and may still have gone concurrent.
  test "states the rule a run that chose nothing followed" do
    assert [sentence] = StepShape.sentences(%{"sensors" => @five_sensors})

    assert sentence =~ "`auto`"
    assert sentence =~ "unless one of them draws"
  end

  test "says a lagged run's deliveries belong to the epoch before" do
    sentences =
      StepShape.sentences(%{
        "scheduling" => "lagged",
        "sensors_step" => "serial",
        "sensors" => ["patch_0"]
      })

    assert [sentence] = sentences
    assert sentence =~ "a step behind"
    assert sentence =~ "the epoch"
  end

  test "says both when both are true" do
    assert length(
             StepShape.sentences(%{
               "scheduling" => "lagged",
               "sensors_step" => "concurrent",
               "sensors" => @five_sensors
             })
           ) == 2
  end
end
