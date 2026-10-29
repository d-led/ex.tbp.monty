defmodule Monty.Simulators.Synthetic.EnvironmentTest do
  @moduledoc """
  What a step of the stand-in world answers, in Monty's own shapes.

  The keys and units are the contract the runtime relies on: observations keyed
  by agent then sensor with positions in the world, proprioception with the
  agent's pose absolute and each sensor's pose relative to it.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{LookUp, MoveForward}
  alias Monty.Simulators.Synthetic.{Environment, Scene}

  @agent "agent_id_0"

  defp forward(distance), do: %MoveForward{agent_id: @agent, distance: distance}

  defp sensor_location(observations, sensor_id \\ "patch") do
    observations |> Map.fetch!(@agent) |> Map.fetch!(sensor_id) |> Map.fetch!("location")
  end

  defp sensor(observations, sensor_id \\ "patch") do
    observations |> Map.fetch!(@agent) |> Map.fetch!(sensor_id)
  end

  test "an observation says where each sensor is in the world" do
    environment = Environment.new(["patch"])

    {observations, _proprioceptive_state, _environment} =
      Environment.step(environment, [forward(0.01)])

    [x, y, z] = sensor_location(observations)

    assert_in_delta x, 0.0, 1.0e-12
    assert_in_delta y, 0.0, 1.0e-12
    assert_in_delta z, 0.09, 1.0e-12
  end

  test "proprioception says where the agent is, and where its sensors sit on it" do
    environment = Environment.new(["patch"])

    {_observations, proprioceptive_state, _environment} =
      Environment.step(environment, [forward(0.01)])

    agent = Map.fetch!(proprioceptive_state, @agent)

    assert Enum.at(agent.position, 2) == -0.01
    # The sensor has not moved relative to the agent it is mounted on.
    assert Enum.at(agent.sensors["patch"].position, 2) == 0.1
  end

  test "a step answers the world it leaves behind, so steps compose" do
    {_observations, _proprioceptive_state, environment} =
      Environment.step(Environment.new(["patch"]), [forward(0.01)])

    {observations, _proprioceptive_state, _environment} =
      Environment.step(environment, [forward(0.01)])

    assert_in_delta Enum.at(sensor_location(observations), 2), 0.08, 1.0e-12
  end

  test "an episode starts where the first one did" do
    {_observations, _proprioceptive_state, environment} =
      Environment.step(Environment.new(["patch"]), [forward(0.01)])

    {observations, _proprioceptive_state, _environment} =
      Environment.step(Environment.reset(environment), [])

    assert_in_delta Enum.at(sensor_location(observations), 2), 0.1, 1.0e-12
  end

  test "an environment with no sensors given still has one to report" do
    {observations, _proprioceptive_state, _environment} =
      Environment.step(Environment.new([]), [])

    assert Map.has_key?(Map.fetch!(observations, @agent), "patch")
  end

  describe "a world with something in it" do
    test "reports the surface under the sensor as a one-pixel image, and its geometry" do
      environment = Environment.new(["patch"], Scene.new(radius: 0.05))

      {observations, _proprioceptive_state, _environment} = Environment.step(environment, [])
      seen = sensor(observations)

      # Monty's code indexes these images, so a world answers an image even when
      # its sensor has a single pixel.
      assert [[depth]] = seen["depth"]
      assert_in_delta depth, 0.05, 1.0e-12
      assert [[1.0]] = seen["semantic"]

      # The normal at the top of the sphere, and the two curvature directions.
      [normal, direction_1, direction_2] = seen["pose_vectors"]
      assert_in_delta Enum.at(normal, 2), 1.0, 1.0e-12
      assert_in_delta Enum.at(direction_1, 2), 0.0, 1.0e-12
      assert_in_delta Enum.at(direction_2, 2), 0.0, 1.0e-12

      assert_in_delta hd(seen["principal_curvatures"]), -20.0, 1.0e-9
    end

    test "and a sensor that looks up sees nothing" do
      # Turning the agent does not look away: the sensor sits above the agent,
      # so it stays pointed at the object. Pitching it is what loses the view.
      environment = Environment.new(["patch"], Scene.new(radius: 0.05))

      {observations, _proprioceptive_state, _environment} =
        Environment.step(environment, [%LookUp{agent_id: @agent, rotation_degrees: 90.0}])

      seen = sensor(observations)

      # Depth 0 is what a depth image has where the camera saw nothing.
      assert [[0.0]] = seen["depth"]
      assert [[0.0]] = seen["semantic"]
      assert seen["pose_vectors"] == nil
      assert seen["principal_curvatures"] == nil
    end
  end

  test "a world with nothing in it says nothing about a surface" do
    {observations, _proprioceptive_state, _environment} =
      Environment.step(Environment.new(["patch"]), [])

    seen = sensor(observations)

    refute Map.has_key?(seen, "depth")
    refute Map.has_key?(seen, "principal_curvatures")
  end
end
