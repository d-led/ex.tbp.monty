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

    # Monty's own surface agent walks towards what the module believes, and the
    # tutorial this set is built on does not turn that off. A set that does is
    # deviating from it: the same four episodes gain twice the evidence with it
    # on, and the same number of objects stay possible either way.
    test "the motor system is asked for goal-driven actions" do
      assert policy()["use_goal_driven_actions"] == true
    end
  end

  describe "the two-patch feature run" do
    # A second patch is a second camera, and Monty's sensor order is what
    # `sm_to_lm_matrix` counts: the patches first, the view finder last, or the
    # learning module is fed the wrong sensor's features.
    test "the learning module reads both patches and not the view finder" do
      monty = compose("cad/plate_features_2patch_eval")

      assert monty["sm_to_lm_matrix"] == [[0, 1]]
      assert Map.keys(monty["sm_to_agent_dict"]) == ["patch", "patch_side", "view_finder"]
    end

    # A module's tolerances are keyed by the sensor that reported the features,
    # so a patch id with no entry is a channel it cannot judge.
    test "the module has tolerances for both patches" do
      lm =
        compose("cad/plate_features_2patch_eval")
        |> get_in(["learning_modules", "learning_module_0"])

      assert Map.keys(lm["tolerances"]) == ["patch", "patch_side"]
    end
  end

  defp policy do
    policy = compose(@experiment) |> get_in(["motor_system_config", "policy_selector", "policy"])

    policy
  end

  defp compose(experiment) do
    {:ok, tree} = Composer.compose(experiment)

    get_in(tree, ["experiment", "config", "monty_config"])
  end
end
