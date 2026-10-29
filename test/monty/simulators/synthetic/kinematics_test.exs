defmodule Monty.Simulators.Synthetic.KinematicsTest do
  @moduledoc """
  The conventions a policy steers the stand-in world by.

  These follow Monty's MuJoCo actuator (`simulators/mujoco/agents.py`), so that
  behaviour written against this world is behaviour against Monty's: forward is
  along the agent's local −Z, turning yaws the agent, looking pitches the
  sensors, and a tangential move follows a direction that is already in world
  coordinates.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{
    LookUp,
    MoveForward,
    MoveTangentially,
    OrientVertical,
    TurnLeft,
    TurnRight
  }

  alias Monty.Geometry.Rotation
  alias Monty.Simulators.Synthetic.Kinematics

  @agent "agent_id_0"

  defp world(sensor_ids \\ ["patch"]), do: Kinematics.new(sensor_ids)

  defp move(world, actions), do: Kinematics.step(world, actions)

  defp sensor_position(world, sensor_id \\ "patch") do
    Map.fetch!(Kinematics.sensor_positions(world), sensor_id)
  end

  defp gaze(world, sensor_id \\ "patch") do
    world
    |> Map.fetch!(:sensors)
    |> Map.fetch!(sensor_id)
    |> Map.fetch!(:rotation)
    |> Rotation.apply([0.0, 0.0, -1.0])
  end

  defp assert_at(position, expected, delta \\ 1.0e-12) do
    expected
    |> Enum.zip(position)
    |> Enum.each(fn {want, got} -> assert_in_delta got, want, delta end)
  end

  describe "moving forward" do
    test "goes where the agent is looking, which is its local -z" do
      world = move(world(), [%MoveForward{agent_id: @agent, distance: 0.01}])

      assert_at(world.agent.position, [0.0, 0.0, -0.01])
      # The sensor rides above the agent, so it is one centimetre further along
      # the same line.
      assert_at(sensor_position(world), [0.0, 0.0, 0.09])
    end

    test "and a negative distance goes backwards" do
      world = move(world(), [%MoveForward{agent_id: @agent, distance: -0.02}])

      assert_at(world.agent.position, [0.0, 0.0, 0.02])
    end
  end

  describe "turning" do
    test "left turns the agent so that forward becomes -x" do
      world =
        move(world(), [
          %TurnLeft{agent_id: @agent, rotation_degrees: 90.0},
          %MoveForward{agent_id: @agent, distance: 0.01}
        ])

      assert_at(world.agent.position, [-0.01, 0.0, 0.0], 1.0e-9)
    end

    test "right turns it the other way" do
      world =
        move(world(), [
          %TurnRight{agent_id: @agent, rotation_degrees: 90.0},
          %MoveForward{agent_id: @agent, distance: 0.01}
        ])

      assert_at(world.agent.position, [0.01, 0.0, 0.0], 1.0e-9)
    end
  end

  describe "looking" do
    test "up tilts the sensors' gaze up, and leaves the agent where it was" do
      before = world()
      world = move(before, [%LookUp{agent_id: @agent, rotation_degrees: 30.0}])

      assert world.agent.position == before.agent.position
      assert world.agent.rotation == before.agent.rotation

      [_x, gaze_y, gaze_z] = gaze(world)
      assert_in_delta gaze_y, :math.sin(:math.pi() / 6.0), 1.0e-9
      assert_in_delta gaze_z, -:math.cos(:math.pi() / 6.0), 1.0e-9
    end

    test "and two sensors of one agent see places a centimetre apart" do
      world = world(["patch", "view_finder"])

      [patch_x, patch_y, patch_z] = sensor_position(world, "patch")
      [finder_x, finder_y, finder_z] = sensor_position(world, "view_finder")

      assert {patch_x, patch_y} == {finder_x, finder_y}
      assert_in_delta finder_z - patch_z, 0.01, 1.0e-12
    end
  end

  describe "moving tangentially" do
    test "follows the direction it is given, in world coordinates" do
      world =
        move(world(), [
          %MoveTangentially{agent_id: @agent, distance: 0.02, direction: [0.0, 1.0, 0.0]}
        ])

      assert_at(world.agent.position, [0.0, 0.02, 0.0])
    end

    test "without being turned by the way the agent happens to face" do
      world =
        move(world(), [
          %TurnLeft{agent_id: @agent, rotation_degrees: 90.0},
          %MoveTangentially{agent_id: @agent, distance: 0.02, direction: [0.0, 1.0, 0.0]}
        ])

      assert_at(world.agent.position, [0.0, 0.02, 0.0])
    end

    test "for the distance asked, even from a direction that is not a unit vector" do
      world =
        move(world(), [
          %MoveTangentially{agent_id: @agent, distance: 0.02, direction: [0.0, 2.0, 0.0]}
        ])

      assert_at(world.agent.position, [0.0, 0.02, 0.0])
    end
  end

  describe "an action the stand-in world cannot honour" do
    test "is refused rather than quietly ignored" do
      assert_raise ArgumentError, ~r/needs a surface/, fn ->
        move(world(), [
          %OrientVertical{
            agent_id: @agent,
            rotation_degrees: 0.0,
            down_distance: 0.0,
            forward_distance: 0.0
          }
        ])
      end
    end
  end
end
