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

    assert sentence =~ "all at once"
    assert sentence =~ "slowest of them, not their sum"
    assert sentence =~ "draws from the episode's stream"
  end

  test "says a serial round costs the sum" do
    assert [sentence] =
             StepShape.sentences(%{"sensors_step" => "serial", "sensors" => @five_sensors})

    assert sentence =~ "one after another"
    assert sentence =~ "their sum"
  end

  # A run that recorded no choice followed the default, and the default is
  # Monty's order — so the sentence says which way the sensors are asked.
  test "states the rule a run that chose nothing followed" do
    assert [sentence] = StepShape.sentences(%{"sensors" => @five_sensors})

    assert sentence =~ "one after another"
    assert sentence =~ "as Monty steps them"
  end

  test "says a lagged run's deliveries belong to the epoch before" do
    sentences =
      StepShape.sentences(%{
        "scheduling" => "lagged",
        "sensors_step" => "serial",
        "sensors" => ["patch_0"]
      })

    assert [sentence] = sentences
    assert sentence =~ "answer a step later"
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

  # The form's select, the step-shape sentences and a stored run's own row are
  # three readers of one choice; they say it in the same words because the words
  # are here, not because three files were edited together.
  test "names the scheduling and sensor choices the way the run form does" do
    assert StepShape.scheduling_choices() == [
             {"wait_for_all", :wait_for_all, "answer in this step"},
             {"one_step_behind", :one_step_behind, "a slow one answers a step later"}
           ]

    assert StepShape.scheduling_word("wait_for_all") == "answer in this step"
    assert StepShape.scheduling_word("lagged") == "a slow one answers a step later"
    assert StepShape.sensor_word("concurrent") == "all at once"
    assert StepShape.sensor_word("nonsense") == "nonsense"
  end
end
