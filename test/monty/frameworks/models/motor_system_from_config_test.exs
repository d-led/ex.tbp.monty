defmodule Monty.Frameworks.Models.MotorSystemFromConfigTest do
  @moduledoc """
  The body a surface-agent experiment describes, built from Monty's own config.

  This is the specification that matters for the motor system: not "the
  constructor takes these options" but "Monty's `base_config_10distinctobj_surf_agent`
  becomes *that* body".
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp
  alias Monty.Context
  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Actions.{MoveForward, MoveTangentially, OrientHorizontal, OrientVertical}
  alias Monty.Frameworks.Models.MotorPolicies.SurfacePolicyCurvatureInformed
  alias Monty.Frameworks.Models.MotorPolicySelectors.SinglePolicySelector
  alias Monty.Frameworks.Models.MotorSystem

  # Monty's own snapshot, read as YAML-free data: the motor block of
  # `tests/conf/snapshots/base_config_10distinctobj_surf_agent.yaml`.
  defp surf_agent_motor_config do
    %{
      "_target_" => "tbp.monty.frameworks.models.motor_system.MotorSystem",
      "policy_selector" => %{
        "_target_" => "tbp.monty.frameworks.models.motor_policy_selectors.SinglePolicySelector",
        "policy" => %{
          "_target_" =>
            "tbp.monty.frameworks.models.motor_policies.SurfacePolicyCurvatureInformed",
          "use_goal_driven_actions" => true,
          "agent_id" => "agent_id_0",
          "desired_object_distance" => 0.025,
          "alpha" => 0.1,
          "pc_alpha" => 0.5,
          "max_pc_bias_steps" => 32,
          "min_general_steps" => 8,
          "min_heading_steps" => 12,
          "action_sampler" => %{
            "_target_" => "tbp.monty.frameworks.actions.action_samplers.ConstantSampler",
            "actions" => [
              "${monty.class:tbp.monty.frameworks.actions.actions.MoveForward}",
              "${monty.class:tbp.monty.frameworks.actions.actions.MoveTangentially}",
              "${monty.class:tbp.monty.frameworks.actions.actions.OrientHorizontal}",
              "${monty.class:tbp.monty.frameworks.actions.actions.OrientVertical}"
            ]
          }
        }
      }
    }
  end

  test "the surf agent's config becomes a curvature-following surface policy" do
    motor_system = MotorSystem.from_config(surf_agent_motor_config())

    assert %MotorSystem{policy_selector: %SinglePolicySelector{policy: policy}} = motor_system
    assert %SurfacePolicyCurvatureInformed{} = policy
  end

  test "with the numbers the config gives it" do
    %MotorSystem{policy_selector: %SinglePolicySelector{policy: policy}} =
      MotorSystem.from_config(surf_agent_motor_config())

    assert policy.agent_id == "agent_id_0"
    assert policy.alpha == 0.1
    assert policy.pc_alpha == 0.5
    assert policy.max_pc_bias_steps == 32
    assert policy.min_general_steps == 8
    assert policy.min_heading_steps == 12
    assert policy.desired_object_distance == 0.025
    assert policy.use_goal_driven_actions
  end

  test "and the four actions the config lets it sample" do
    %MotorSystem{policy_selector: %SinglePolicySelector{policy: policy}} =
      MotorSystem.from_config(surf_agent_motor_config())

    assert %ConstantSampler{actions: actions} = policy.action_sampler
    assert actions == [MoveForward, MoveTangentially, OrientHorizontal, OrientVertical]
  end

  test "a policy parameter no policy takes is refused" do
    config =
      update_in(
        surf_agent_motor_config(),
        ["policy_selector", "policy"],
        &Map.put(&1, "colour", "blue")
      )

    assert_raise ArgumentError, ~r/a motor policy takes no "colour"/, fn ->
      MotorSystem.from_config(config)
    end
  end

  test "a policy missing a parameter it cannot do without fails at build time" do
    config =
      update_in(
        surf_agent_motor_config(),
        ["policy_selector", "policy"],
        &Map.delete(&1, "max_pc_bias_steps")
      )

    assert_raise KeyError, fn -> MotorSystem.from_config(config) end
  end

  describe "the body it builds steps" do
    # A percept from an object filling the view, far enough away to move towards.
    defp percept do
      {:ok, message} =
        Cmp.Message.new(
          location: [0.0, 0.0, 0.0],
          morphological_features: %{
            "pose_vectors" =>
              Monty.Geometry.SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [
                0.0,
                1.0,
                0.0
              ]),
            "pose_fully_defined" => true
          },
          non_morphological_features: %{
            "object_coverage" => 1.0,
            "mean_depth" => 0.04,
            "min_depth" => 0.04,
            "principal_curvatures" => [1.0, 5.0]
          },
          confidence: 1.0,
          pass_message: true,
          process_features_in_lm: false,
          sender_id: "patch",
          sender_type: :sm
        )

      message
    end

    defp proprioceptive_state do
      %{
        "agent_id_0" => %{
          sensors: %{},
          position: [0.0, 0.0, 0.0],
          rotation: Monty.Geometry.Rotation.identity()
        }
      }
    end

    test "answers an action, and remembers the state it was chosen in" do
      motor_system = MotorSystem.from_config(surf_agent_motor_config())

      {actions, motor_system} =
        MotorSystem.call(
          motor_system,
          Context.new(0),
          nil,
          proprioceptive_state(),
          percept(),
          []
        )

      assert [action] = actions
      assert action.agent_id == "agent_id_0"
      assert MotorSystem.action_sequence(motor_system) == [{actions, proprioceptive_state()}]
    end

    test "and reports a step that only moves the sensor into place as motor-only" do
      # The first step of a surface episode is a corrective turn, not something
      # a learning module has anything to say about.
      {actions, motor_system} =
        MotorSystem.call(
          MotorSystem.from_config(surf_agent_motor_config()),
          Context.new(0),
          nil,
          proprioceptive_state(),
          percept(),
          []
        )

      assert [%OrientHorizontal{}] = actions
      assert MotorSystem.motor_only_step(motor_system)
    end
  end
end
