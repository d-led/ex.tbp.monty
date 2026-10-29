defmodule Monty.Simulators.Synthetic.EnvironmentTest do
  @moduledoc """
  What a step of the stand-in world answers, in Monty's own shapes.

  The keys and units are the contract the runtime relies on: observations keyed
  by agent then sensor with positions in the world, proprioception with the
  agent's pose absolute and each sensor's pose relative to it.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.MoveForward
  alias Monty.Simulators.Synthetic.Environment

  @agent "agent_id_0"

  defp forward(distance), do: %MoveForward{agent_id: @agent, distance: distance}

  defp sensor_location(observations, sensor_id \\ "patch") do
    observations |> Map.fetch!(@agent) |> Map.fetch!(sensor_id) |> Map.fetch!("location")
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

    assert Enum.at(agent["position"], 2) == -0.01
    # The sensor has not moved relative to the agent it is mounted on.
    assert Enum.at(get_in(agent, ["sensors", "patch", "position"]), 2) == 0.1
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
end
