defmodule Monty.Frameworks.Actions.ActionSamplersMontyTest do
  @moduledoc """
  Translations of `tests/unit/frameworks/actions/action_samplers_test.py`.

  One case for one case, in Monty's order: the base sampler's dispatch, then the
  fourteen kinds a constant sampler makes, then the same fourteen a uniformly
  distributed sampler draws. The numbers are Monty's own fixture — 45 degrees
  absolute, 4 turning, 0.02 m, the ranges 15–45, 180–360 and 0.3–0.5 — and the
  stream is seeded with Monty's `RNG_SEED`.

  Two things are necessarily not the same. Monty's cases call `sample_<kind>` with
  a `RandomState` it spends across both calls; here the stream is a process, and
  the two calls in a case take the same one, which is what one `RandomState`
  shared by two calls is. And Monty's base case uses three *fake* action classes
  with an empty `act`; this port has no fake actions in its test tree, so the case
  uses three real ones. What it asserts — a hundred draws are not all one kind,
  and asking the kind it drew makes that same action — is the property a fake
  exists to test, and does not depend on which classes those are.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.ActionSamplers.{
    ActionSampler,
    ConstantSampler,
    UniformlyDistributedSampler
  }

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

  # Monty's module-level fixture.
  @agent_1 "agent_id_1"
  @agent_2 "agent_id_2"
  @rng_seed 1337

  # `ConstantSamplerTest.setUp`.
  @absolute_degrees 45.0
  @direction [1.0, 2.0, 3.0]
  @location [4.0, 5.0, 6.0]
  @rotation_degrees 4.0
  @rotation_quat {0.0, 0.0, 0.0, 1.0}
  @translation_distance 0.02

  # `UniformlyDistributedSamplerTest.setUp`.
  @rotation_range {15.0, 45.0}
  @absolute_range {180.0, 360.0}
  @translation_range {0.3, 0.5}

  defp constant_sampler do
    ConstantSampler.new(
      absolute_degrees: @absolute_degrees,
      direction: @direction,
      location: @location,
      rotation_quat: @rotation_quat,
      rotation_degrees: @rotation_degrees,
      translation_distance: @translation_distance
    )
  end

  defp uniform_sampler do
    UniformlyDistributedSampler.new(
      min_absolute_degrees: elem(@absolute_range, 0),
      max_absolute_degrees: elem(@absolute_range, 1),
      min_rotation_degrees: elem(@rotation_range, 0),
      max_rotation_degrees: elem(@rotation_range, 1),
      min_translation: elem(@translation_range, 0),
      max_translation: elem(@translation_range, 1)
    )
  end

  # The two calls Monty's cases make: two agents, one stream, in that order.
  defp twice(module, sampler, kind) do
    stream = Monty.EpisodeStream.start(@rng_seed)

    {apply(module, :"sample_#{kind}", [sampler, @agent_1, stream]),
     apply(module, :"sample_#{kind}", [sampler, @agent_2, stream])}
  end

  defp within?({low, high}, value), do: value >= low and value <= high

  # Monty's `assertNotAlmostEqual` at its default seven places.
  defp differs?(first, second), do: abs(first - second) > 1.0e-7

  defp each_differs?(first, second) do
    Enum.zip(first, second) |> Enum.all?(fn {one, other} -> differs?(one, other) end)
  end

  describe "choosing which action to make" do
    # test_sample_samples_random_action
    test "a hundred draws are not one kind, and each is what its own kind makes" do
      sampler =
        ConstantSampler.new(
          actions: [LookDown, MoveForward, TurnLeft],
          rotation_degrees: 7.0,
          translation_distance: 0.02
        )

      ctx = Monty.EpisodeStream.context(@rng_seed)

      drawn = for _step <- 1..100, do: ActionSampler.sample(sampler, @agent_1, ctx)

      assert drawn |> Enum.map(& &1.__struct__) |> Enum.uniq() |> length() > 1

      for action <- drawn do
        again =
          apply(ConstantSampler, :"sample_#{action.__struct__.name()}", [
            sampler,
            @agent_1,
            Monty.Context.rng(ctx)
          ])

        assert again == action
      end
    end
  end

  describe "a constant parameter never changes" do
    # test_samples_look_down_with_constant_params
    test "looking down turns by the configured degrees, within 90 of the body" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :look_down)

      for action <- [first, second] do
        assert %LookDown{rotation_degrees: @rotation_degrees, constraint_degrees: 90.0} = action
      end
    end

    # test_samples_look_up_with_constant_params
    test "looking up turns by the configured degrees, within 90 of the body" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :look_up)

      for action <- [first, second] do
        assert %LookUp{rotation_degrees: @rotation_degrees, constraint_degrees: 90.0} = action
      end
    end

    # test_samples_move_forward_with_constant_params
    test "moving forward goes the configured distance" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :move_forward)

      for action <- [first, second] do
        assert %MoveForward{distance: @translation_distance} = action
      end
    end

    # test_samples_move_tangentially_with_constant_params
    test "moving tangentially goes the configured distance, the configured way" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :move_tangentially)

      for action <- [first, second] do
        assert %MoveTangentially{distance: @translation_distance, direction: @direction} = action
      end
    end

    # test_samples_orient_horizontal_with_constant_params
    test "orienting horizontally turns and moves by the configured amounts" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :orient_horizontal)

      for action <- [first, second] do
        assert %OrientHorizontal{
                 rotation_degrees: @rotation_degrees,
                 left_distance: @translation_distance,
                 forward_distance: @translation_distance
               } = action
      end
    end

    # test_samples_orient_vertical_with_constant_params
    test "orienting vertically turns and moves by the configured amounts" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :orient_vertical)

      for action <- [first, second] do
        assert %OrientVertical{
                 rotation_degrees: @rotation_degrees,
                 down_distance: @translation_distance,
                 forward_distance: @translation_distance
               } = action
      end
    end

    # test_samples_set_agent_pitch_with_constant_params
    test "setting the agent's pitch uses the absolute angle" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :set_agent_pitch)

      for action <- [first, second] do
        assert %SetAgentPitch{pitch_degrees: @absolute_degrees} = action
      end
    end

    # test_samples_set_agent_pose_with_constant_params
    test "setting the agent's pose uses the configured place and orientation" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :set_agent_pose)

      for action <- [first, second] do
        assert %SetAgentPose{location: location, rotation_quat: quaternion} = action
        assert {location, quaternion} == {@location, @rotation_quat}
      end
    end

    # test_samples_set_sensor_pitch_with_constant_params
    test "setting a sensor's pitch uses the absolute angle" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :set_sensor_pitch)

      for action <- [first, second] do
        assert %SetSensorPitch{pitch_degrees: @absolute_degrees} = action
      end
    end

    # test_samples_set_sensor_pose_with_constant_params
    test "setting a sensor's pose uses the configured place and orientation" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :set_sensor_pose)

      for action <- [first, second] do
        assert %SetSensorPose{location: location, rotation_quat: quaternion} = action
        assert {location, quaternion} == {@location, @rotation_quat}
      end
    end

    # test_samples_set_sensor_rotation_with_constant_params
    test "setting a sensor's rotation uses the configured orientation" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :set_sensor_rotation)

      for action <- [first, second] do
        assert %SetSensorRotation{rotation_quat: quaternion} = action
        assert quaternion == @rotation_quat
      end
    end

    # test_samples_set_yaw_with_constant_params
    test "setting yaw uses the absolute angle" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :set_yaw)

      for action <- [first, second] do
        assert %SetYaw{rotation_degrees: @absolute_degrees} = action
      end
    end

    # test_samples_turn_left_with_constant_params
    test "turning left uses the turning angle" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :turn_left)

      for action <- [first, second] do
        assert %TurnLeft{rotation_degrees: @rotation_degrees} = action
      end
    end

    # test_samples_turn_right_with_constant_params
    test "turning right uses the turning angle" do
      {first, second} = twice(ConstantSampler, constant_sampler(), :turn_right)

      for action <- [first, second] do
        assert %TurnRight{rotation_degrees: @rotation_degrees} = action
      end
    end
  end

  describe "a drawn parameter comes from its range" do
    # test_samples_look_down_with_sampled_params
    test "looking down draws two different angles from the turning range" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :look_down)

      for %LookDown{rotation_degrees: degrees, constraint_degrees: 90.0} <- [first, second] do
        assert within?(@rotation_range, degrees)
      end

      assert differs?(first.rotation_degrees, second.rotation_degrees)
    end

    # test_samples_look_up_with_sampled_params
    test "looking up draws two different angles from the turning range" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :look_up)

      for %LookUp{rotation_degrees: degrees, constraint_degrees: 90.0} <- [first, second] do
        assert within?(@rotation_range, degrees)
      end

      assert differs?(first.rotation_degrees, second.rotation_degrees)
    end

    # test_samples_move_forward_with_sampled_params
    test "moving forward draws two different distances from the translation range" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :move_forward)

      for %MoveForward{distance: distance} <- [first, second] do
        assert within?(@translation_range, distance)
      end

      assert differs?(first.distance, second.distance)
    end

    # test_samples_move_tangentially_with_sampled_params
    test "moving tangentially draws a distance and a direction of its own" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :move_tangentially)

      for %MoveTangentially{distance: distance} <- [first, second] do
        assert within?(@translation_range, distance)
      end

      assert differs?(first.distance, second.distance)
      assert each_differs?(first.direction, second.direction)
    end

    # test_samples_orient_horizontal_with_sample_params
    test "orienting horizontally draws its turn and both distances" do
      {first, second} =
        twice(UniformlyDistributedSampler, uniform_sampler(), :orient_horizontal)

      for %OrientHorizontal{
            rotation_degrees: degrees,
            left_distance: left,
            forward_distance: forward
          } <- [first, second] do
        assert within?(@rotation_range, degrees)
        assert within?(@translation_range, left)
        assert within?(@translation_range, forward)
      end

      assert differs?(first.rotation_degrees, second.rotation_degrees)
      assert differs?(first.left_distance, second.left_distance)
      assert differs?(first.forward_distance, second.forward_distance)
    end

    # test_samples_orient_vertical_with_sample_params
    test "orienting vertically draws its turn and both distances" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :orient_vertical)

      for %OrientVertical{
            rotation_degrees: degrees,
            down_distance: down,
            forward_distance: forward
          } <- [first, second] do
        assert within?(@rotation_range, degrees)
        assert within?(@translation_range, down)
        assert within?(@translation_range, forward)
      end

      assert differs?(first.rotation_degrees, second.rotation_degrees)
      assert differs?(first.down_distance, second.down_distance)
      assert differs?(first.forward_distance, second.forward_distance)
    end

    # test_samples_set_agent_pitch_with_sample_params
    test "setting the agent's pitch draws two different angles from the absolute range" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :set_agent_pitch)

      for %SetAgentPitch{pitch_degrees: pitch} <- [first, second] do
        assert within?(@absolute_range, pitch)
      end

      assert differs?(first.pitch_degrees, second.pitch_degrees)
    end

    # test_samples_set_agent_pose_with_sample_params
    test "setting the agent's pose draws a place and an orientation of its own" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :set_agent_pose)

      assert each_differs?(first.location, second.location)

      assert each_differs?(
               Tuple.to_list(first.rotation_quat),
               Tuple.to_list(second.rotation_quat)
             )
    end

    # test_samples_set_sensor_pitch_with_sample_params
    test "setting a sensor's pitch draws two different angles from the absolute range" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :set_sensor_pitch)

      for %SetSensorPitch{pitch_degrees: pitch} <- [first, second] do
        assert within?(@absolute_range, pitch)
      end

      assert differs?(first.pitch_degrees, second.pitch_degrees)
    end

    # test_samples_set_sensor_pose_with_sample_params
    test "setting a sensor's pose draws a place and an orientation of its own" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :set_sensor_pose)

      assert each_differs?(first.location, second.location)

      assert each_differs?(
               Tuple.to_list(first.rotation_quat),
               Tuple.to_list(second.rotation_quat)
             )
    end

    # test_samples_set_sensor_rotation_with_sample_params
    test "setting a sensor's rotation draws an orientation of its own" do
      {first, second} =
        twice(UniformlyDistributedSampler, uniform_sampler(), :set_sensor_rotation)

      assert each_differs?(
               Tuple.to_list(first.rotation_quat),
               Tuple.to_list(second.rotation_quat)
             )
    end

    # test_samples_set_yaw_with_sample_params
    test "setting yaw draws two different angles from the absolute range" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :set_yaw)

      for %SetYaw{rotation_degrees: degrees} <- [first, second] do
        assert within?(@absolute_range, degrees)
      end

      assert differs?(first.rotation_degrees, second.rotation_degrees)
    end

    # test_samples_turn_left_with_sample_params
    test "turning left draws two different angles from the turning range" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :turn_left)

      for %TurnLeft{rotation_degrees: degrees} <- [first, second] do
        assert within?(@rotation_range, degrees)
      end

      assert differs?(first.rotation_degrees, second.rotation_degrees)
    end

    # test_samples_turn_right_with_sample_params
    test "turning right draws two different angles from the turning range" do
      {first, second} = twice(UniformlyDistributedSampler, uniform_sampler(), :turn_right)

      for %TurnRight{rotation_degrees: degrees} <- [first, second] do
        assert within?(@rotation_range, degrees)
      end

      assert differs?(first.rotation_degrees, second.rotation_degrees)
    end
  end
end
