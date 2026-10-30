defmodule Monty.Simulators.Port.EnvironmentTest do
  @moduledoc """
  The port, against a real process on the other side of it.

  The peer is `test/support/probe_world.py`: a Python process that answers the
  protocol's two requests and hands back what it was sent. It is not a world —
  the point of these tests is the boundary itself, which is what a simulator
  written in Python will meet.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Actions.{MoveForward, TurnLeft}
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Simulators.Port.Environment

  @peer Path.expand("../../../support/probe_world.py", __DIR__)

  defp start_environment(options \\ []) do
    start_supervised!(
      {Environment,
       Keyword.merge(
         [
           command: [System.find_executable("python3"), @peer],
           sensor_ids: ["patch"]
         ],
         options
       )}
    )
  end

  test "a step is answered with observations and proprioceptive state" do
    environment = start_environment()

    assert {:ok, observations, proprioceptive_state} =
             Environment.step(environment, [
               %MoveForward{agent_id: "agent_id_0", distance: 0.004}
             ])

    location = get_in(observations, ["agent_id_0", "patch", "location"])
    assert_in_delta Enum.at(location, 2), 0.1, 1.0e-12

    # The reply's maps are Monty's own (`wxyz` rotations, one agent per key);
    # what a step answers with is the port's state, ready for the motor system.
    assert %{"agent_id_0" => %AgentState{} = agent} = proprioceptive_state
    assert agent.position == [0.0, 0.0, 0.0]

    assert %{"patch" => %SensorState{} = patch} = agent.sensors
    assert patch.position == [0.0, 0.0, 0.1]
  end

  test "the actions arrive as Monty's action maps" do
    environment = start_environment()

    {:ok, observations, _state} =
      Environment.step(environment, [
        %MoveForward{agent_id: "agent_id_0", distance: 0.01},
        %TurnLeft{agent_id: "agent_id_0", rotation_degrees: 5.0}
      ])

    seen = get_in(observations, ["agent_id_0", "patch", "actions_seen"])

    assert [
             %{"action" => "move_forward", "distance" => 0.01},
             %{"action" => "turn_left", "rotation_degrees" => 5.0}
           ] = seen
  end

  test "a fresh episode answers what that episode is about" do
    assert {:ok, %{"primary_target" => %{"object" => "probe"}}} =
             Environment.reset(start_environment())
  end

  test "each step is answered by its own reply" do
    environment = start_environment()

    {:ok, first, _state} =
      Environment.step(environment, [%TurnLeft{agent_id: "agent_id_0", rotation_degrees: 1.0}])

    {:ok, second, _state} =
      Environment.step(environment, [
        %MoveForward{agent_id: "agent_id_0", distance: 0.01},
        %MoveForward{agent_id: "agent_id_0", distance: 0.02},
        %TurnLeft{agent_id: "agent_id_0", rotation_degrees: 5.0}
      ])

    assert length(get_in(first, ["agent_id_0", "patch", "actions_seen"])) == 1
    assert length(get_in(second, ["agent_id_0", "patch", "actions_seen"])) == 3
  end

  test "a simulator that does not answer is an error, not a step without an observation" do
    environment =
      start_supervised!(
        {Environment, command: [System.find_executable("python3"), @peer, "silent"], timeout: 50}
      )

    assert Environment.step(environment, [
             %TurnLeft{agent_id: "agent_id_0", rotation_degrees: 1.0}
           ]) ==
             {:error, :timeout}
  end

  test "a peer that echoes the request is reported, not read as an observation" do
    # `cat` echoes the request back, so the reply is this port's own frame.
    environment = start_supervised!({Environment, command: ["cat"], timeout: 500})

    assert {:error, _reason} =
             Environment.step(environment, [
               %TurnLeft{agent_id: "agent_id_0", rotation_degrees: 1.0}
             ])
  end
end
