defmodule Monty.Frameworks.Actions.ActionSamplers.UniformlyDistributedSamplerTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{
    LookDown,
    MoveForward,
    MoveTangentially,
    OrientHorizontal,
    OrientVertical,
    SetAgentPitch,
    SetAgentPose,
    SetSensorRotation,
    SetYaw,
    TurnLeft
  }

  alias Monty.Frameworks.Actions.ActionSamplers.UniformlyDistributedSampler

  @agent "agent_id_0"

  @rotation {15.0, 45.0}
  @absolute {180.0, 360.0}
  @translation {0.3, 0.5}

  defp within?({low, high}, value), do: value >= low and value <= high

  # Monty's test fixtures: ranges narrow enough that a value outside one is
  # unmistakable, and wide enough that two draws are almost never equal.
  defp sampler do
    UniformlyDistributedSampler.new(
      min_rotation_degrees: 15.0,
      max_rotation_degrees: 45.0,
      min_absolute_degrees: 180.0,
      max_absolute_degrees: 360.0,
      min_translation: 0.3,
      max_translation: 0.5
    )
  end

  defp two_draws(kind) do
    rng = :rand.seed_s(:exsss, {1, 2, 3})
    {first, rng} = apply(UniformlyDistributedSampler, :"sample_#{kind}", [sampler(), @agent, rng])

    {second, _rng} =
      apply(UniformlyDistributedSampler, :"sample_#{kind}", [sampler(), @agent, rng])

    {first, second}
  end

  defp draw(kind) do
    rng = :rand.seed_s(:exsss, {1, 2, 3})

    {action, _rng} =
      apply(UniformlyDistributedSampler, :"sample_#{kind}", [sampler(), @agent, rng])

    action
  end

  describe "the degrees a turn draws" do
    test "are inside the configured turning range, and not the same twice" do
      {first, second} = two_draws(:turn_left)

      for %TurnLeft{rotation_degrees: degrees} <- [first, second] do
        assert within?(@rotation, degrees)
      end

      assert first.rotation_degrees != second.rotation_degrees
    end

    test "looking down and up draw from the same range, within 90 of the body" do
      assert %LookDown{rotation_degrees: down, constraint_degrees: 90.0} = draw(:look_down)
      assert within?(@rotation, down)
    end
  end

  describe "the distances a move draws" do
    test "are inside the configured translation range" do
      {first, second} = two_draws(:move_forward)

      for %MoveForward{distance: distance} <- [first, second] do
        assert within?(@translation, distance)
      end

      assert first.distance != second.distance
    end

    test "an orienting move draws three of them: its turn and both distances" do
      assert %OrientHorizontal{
               rotation_degrees: degrees,
               left_distance: left,
               forward_distance: forward
             } = draw(:orient_horizontal)

      assert within?(@rotation, degrees)
      assert within?(@translation, left)
      assert within?(@translation, forward)
    end

    test "orienting vertically draws a down distance instead of a left one" do
      assert %OrientVertical{
               rotation_degrees: degrees,
               down_distance: down,
               forward_distance: forward
             } = draw(:orient_vertical)

      assert within?(@rotation, degrees)
      assert within?(@translation, down)
      assert within?(@translation, forward)
    end
  end

  describe "the absolute angles" do
    test "pitch and yaw draw from the absolute range, not the turning one" do
      assert %SetAgentPitch{pitch_degrees: pitch} = draw(:set_agent_pitch)
      assert %SetYaw{rotation_degrees: yaw} = draw(:set_yaw)

      assert within?(@absolute, pitch)
      assert within?(@absolute, yaw)
    end
  end

  describe "the poses" do
    test "a pose is somewhere in the unit cube, and a unit quaternion" do
      assert %SetAgentPose{location: [x, y, z], rotation_quat: quaternion} = draw(:set_agent_pose)

      for component <- [x, y, z] do
        assert component >= 0.0 and component < 1.0
      end

      assert_in_delta unit_length(quaternion), 1.0, 1.0e-12
    end

    test "a sensor rotation is a unit quaternion" do
      assert %SetSensorRotation{rotation_quat: quaternion} = draw(:set_sensor_rotation)
      assert_in_delta unit_length(quaternion), 1.0, 1.0e-12
    end
  end

  describe "a tangential move" do
    test "draws a distance and a direction in the unit cube" do
      assert %MoveTangentially{distance: distance, direction: [x, y, z]} =
               draw(:move_tangentially)

      assert within?(@translation, distance)
      for component <- [x, y, z], do: assert(component >= 0.0 and component < 1.0)
    end
  end

  describe "when both ends of a range are the same" do
    test "that parameter does not move, which is Monty's default for a translation" do
      default = UniformlyDistributedSampler.new()
      rng = :rand.seed_s(:exsss, {1, 2, 3})

      {first, rng} = UniformlyDistributedSampler.sample_move_forward(default, @agent, rng)
      {second, _rng} = UniformlyDistributedSampler.sample_move_forward(default, @agent, rng)

      assert first.distance == second.distance
      assert first.distance == 0.05
    end
  end

  defp unit_length({w, x, y, z}), do: :math.sqrt(w * w + x * x + y * y + z * z)
end
