defmodule Monty.Frameworks.Actions.ActionSamplers.ConstantSamplerTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{
    LookDown,
    LookUp,
    MoveForward,
    MoveTangentially,
    OrientHorizontal,
    OrientVertical,
    SetAgentPitch,
    SetAgentPose,
    SetSensorPitch,
    SetSensorPose,
    SetSensorRotation,
    SetYaw,
    TurnLeft,
    TurnRight
  }

  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler

  @agent "agent_id_0"
  @quaternion {0.5, 0.5, 0.5, 0.5}

  # Monty's test fixtures: every parameter set to something that is not the
  # default, so a sampler that ignored its configuration would be visible.
  defp sampler do
    ConstantSampler.new(
      absolute_degrees: 45.0,
      direction: [1.0, 2.0, 3.0],
      location: [4.0, 5.0, 6.0],
      rotation_degrees: 4.0,
      rotation_quat: @quaternion,
      translation_distance: 0.02
    )
  end

  defp rng, do: :rand.seed_s(:exsss, {1, 2, 3})

  # Monty compares two samples of the same kind and the configured value, in one
  # assertion; the same here, per kind.
  defp sample(kind), do: apply(ConstantSampler, :"sample_#{kind}", [sampler(), @agent, rng()])

  describe "the action parameters never change" do
    test "looking down and up turn by the configured degrees, within 90 of the body" do
      assert {%LookDown{rotation_degrees: 4.0, constraint_degrees: 90.0}, _rng} =
               sample(:look_down)

      assert {%LookUp{rotation_degrees: 4.0, constraint_degrees: 90.0}, _rng} = sample(:look_up)
    end

    test "moving forward goes the configured distance" do
      assert {%MoveForward{distance: 0.02}, _rng} = sample(:move_forward)
    end

    test "moving tangentially goes the configured distance, the configured way" do
      assert {%MoveTangentially{distance: 0.02, direction: [1.0, 2.0, 3.0]}, _rng} =
               sample(:move_tangentially)
    end

    test "orienting horizontally turns and moves by the configured amounts" do
      assert {%OrientHorizontal{
                rotation_degrees: 4.0,
                left_distance: 0.02,
                forward_distance: 0.02
              }, _rng} = sample(:orient_horizontal)
    end

    test "orienting vertically turns and moves by the configured amounts" do
      assert {%OrientVertical{
                rotation_degrees: 4.0,
                down_distance: 0.02,
                forward_distance: 0.02
              }, _rng} = sample(:orient_vertical)
    end

    test "the pitch actions use the absolute angle, not the turning one" do
      assert {%SetAgentPitch{pitch_degrees: 45.0}, _rng} = sample(:set_agent_pitch)
      assert {%SetSensorPitch{pitch_degrees: 45.0}, _rng} = sample(:set_sensor_pitch)
    end

    test "the pose actions use the configured place and orientation" do
      assert {%SetAgentPose{location: [4.0, 5.0, 6.0], rotation_quat: @quaternion}, _rng} =
               sample(:set_agent_pose)

      assert {%SetSensorPose{location: [4.0, 5.0, 6.0], rotation_quat: @quaternion}, _rng} =
               sample(:set_sensor_pose)

      assert {%SetSensorRotation{rotation_quat: @quaternion}, _rng} = sample(:set_sensor_rotation)
    end

    test "yaw uses the absolute angle, and turning uses the turning one" do
      assert {%SetYaw{rotation_degrees: 45.0}, _rng} = sample(:set_yaw)
      assert {%TurnLeft{rotation_degrees: 4.0}, _rng} = sample(:turn_left)
      assert {%TurnRight{rotation_degrees: 4.0}, _rng} = sample(:turn_right)
    end
  end

  describe "what it does to the stream" do
    test "draws nothing, so the caller's next draw is unaffected" do
      {_action, rng} = sample(:look_down)
      assert rng == rng()
    end

    test "asks for two agents' actions that differ only in whose they are" do
      {first, _rng} = ConstantSampler.sample_move_forward(sampler(), "agent_id_0", rng())
      {second, _rng} = ConstantSampler.sample_move_forward(sampler(), "agent_id_1", rng())

      assert first.distance == second.distance
      assert {first.agent_id, second.agent_id} == {"agent_id_0", "agent_id_1"}
    end
  end
end
