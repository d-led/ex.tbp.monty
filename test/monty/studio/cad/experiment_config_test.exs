defmodule Monty.Studio.Cad.ExperimentConfigTest do
  @moduledoc """
  A feature run's scale: a CAD feature is a centimetre, so the experiment sizes
  the sensor's stand-off and the policy's step to it.

  Both numbers are choices about size rather than treatment of a shape — one
  stand-off and one gait for every feature the part is made of — and the code
  around them is Monty's. These cases compose the shipped experiment and read
  the two numbers out of the tree, which is the seam a wrong edit reaches first:
  a body written at the wrong package composes to a value nobody reads, and the
  run then steps at the tutorial's size without saying so.
  """

  use ExUnit.Case, async: true

  alias Monty.Config.Composer

  @experiment "cad/plate_features_eval"

  describe "the size a feature run works at" do
    # The patch covers twice its stand-off, so a feature a centimetre across
    # needs a stand-off far under it: Monty's twenty-five millimetres is a
    # patch of five, which is a feature's whole width.
    test "the policy stands eight millimetres off the surface" do
      assert policy()["desired_object_distance"] == 0.008
    end

    # Four millimetres a step is a quarter of a centimetre feature — a crossing
    # in two or three steps, the rest of the episode spent walking back. A
    # millimetre keeps the arc per turn the same and covers a feature in ten.
    test "the policy steps a millimetre and turns a degree" do
      sampler = policy()["action_sampler"]

      assert sampler["translation_distance"] == 0.001
      assert sampler["rotation_degrees"] == 1.0
    end
  end

  defp policy do
    {:ok, tree} = Composer.compose(@experiment)

    get_in(tree, [
      "experiment",
      "config",
      "monty_config",
      "motor_system_config",
      "policy_selector",
      "policy"
    ])
  end
end
