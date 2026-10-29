defmodule Monty.Config.TargetTest do
  use ExUnit.Case, async: true

  alias Monty.Config.Target

  describe "naming a class the port has" do
    test "answers its module" do
      assert Target.class!("tbp.monty.frameworks.models.motor_system.MotorSystem") ==
               Monty.Frameworks.Models.MotorSystem
    end

    test "whether the name arrives as a class interpolation or a bare path" do
      interpolated = "${monty.class:tbp.monty.frameworks.actions.actions.MoveForward}"

      assert Target.class!(interpolated) ==
               Target.class!("tbp.monty.frameworks.actions.actions.MoveForward")
    end
  end

  describe "naming a class the port does not have" do
    test "is refused rather than stood in for" do
      # `Monty` itself is in the map but not built here.
      assert_raise ArgumentError, ~r/not built in this port/, fn ->
        Target.class!("tbp.monty.frameworks.models.abstract_monty_classes.Monty")
      end
    end

    test "and a class Monty does not have is refused too" do
      assert_raise ArgumentError, ~r/is not a class Monty's source has/, fn ->
        Target.class!("tbp.monty.frameworks.models.motor_policies.NonexistentPolicy")
      end
    end
  end

  describe "asking whether a whole config is built here" do
    test "every class it names has to be" do
      built = %{
        "_target_" => "tbp.monty.frameworks.models.motor_system.MotorSystem",
        "policy_selector" => %{
          "_target_" => "tbp.monty.frameworks.models.motor_policy_selectors.SinglePolicySelector",
          "policy" => %{
            "_target_" =>
              "tbp.monty.frameworks.models.motor_policies.SurfacePolicyCurvatureInformed"
          }
        }
      }

      assert Target.implemented?(built)

      not_built =
        put_in(
          built,
          ["policy_selector", "policy", "_target_"],
          "tbp.monty.frameworks.models.abstract_monty_classes.Monty"
        )

      refute Target.implemented?(not_built)
    end
  end
end
