defmodule Monty.Frameworks.Models.DistantMotorSystemFromConfigTest do
  @moduledoc """
  The distant agent's body, from Monty's own config: three policies and a
  selector that routes goals between them.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Actions.{LookDown, LookUp, TurnLeft, TurnRight}
  alias Monty.Frameworks.Models.MotorPolicies.{InformedPolicyRandomWalk, JumpToGoal}
  alias Monty.Frameworks.Models.MotorPolicySelectors.DistantPolicySelector
  alias Monty.Frameworks.Models.MotorSystem
  alias Monty.Frameworks.Models.Salience.MotorPolicy.LookAtGoal

  # The motor block of Monty's `tests/conf/snapshots/base_config_10distinctobj_dist_agent.yaml`.
  defp distant_agent_motor_config do
    %{
      "_target_" => "tbp.monty.frameworks.models.motor_system.MotorSystem",
      "policy_selector" => %{
        "_target_" => "tbp.monty.frameworks.models.motor_policy_selectors.DistantPolicySelector",
        "jump_to_goal" => %{
          "_target_" => "${monty.class:tbp.monty.frameworks.models.motor_policies.JumpToGoal}",
          "agent_id" => "agent_id_0",
          "sensor_id" => "view_finder"
        },
        "look_at_goal" => %{
          "_target_" =>
            "${monty.class:tbp.monty.frameworks.models.salience.motor_policy.LookAtGoal}",
          "agent_id" => "agent_id_0",
          "sensor_id" => "view_finder"
        },
        "default" => %{
          "_target_" =>
            "${monty.class:tbp.monty.frameworks.models.motor_policies.InformedPolicyRandomWalk}",
          "agent_id" => "agent_id_0",
          "action_sampler" => %{
            "_target_" => "tbp.monty.frameworks.actions.action_samplers.ConstantSampler",
            "actions" => [
              "${monty.class:tbp.monty.frameworks.actions.actions.LookUp}",
              "${monty.class:tbp.monty.frameworks.actions.actions.LookDown}",
              "${monty.class:tbp.monty.frameworks.actions.actions.TurnLeft}",
              "${monty.class:tbp.monty.frameworks.actions.actions.TurnRight}"
            ],
            "rotation_degrees" => 5.0
          }
        }
      }
    }
  end

  test "the distant agent's config becomes a selector of three policies" do
    %MotorSystem{policy_selector: selector} =
      MotorSystem.from_config(distant_agent_motor_config())

    assert %DistantPolicySelector{
             jump_to_goal: %JumpToGoal{agent_id: "agent_id_0", sensor_id: "view_finder"},
             look_at_goal: %LookAtGoal{agent_id: "agent_id_0", sensor_id: "view_finder"},
             default: %InformedPolicyRandomWalk{agent_id: "agent_id_0"}
           } = selector
  end

  test "and the walking policy samples the four looking actions the config lists" do
    %MotorSystem{policy_selector: %DistantPolicySelector{default: walk}} =
      MotorSystem.from_config(distant_agent_motor_config())

    assert %ConstantSampler{actions: actions, rotation_degrees: 5.0} = walk.action_sampler
    assert actions == [LookUp, LookDown, TurnLeft, TurnRight]
  end
end
