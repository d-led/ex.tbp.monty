defmodule Monty.Frameworks.Models.Salience.MotorPolicy.LookAtGoalTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Goal
  alias Monty.Context
  alias Monty.Frameworks.Actions.{LookUp, TurnLeft}
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  alias Monty.Frameworks.Models.MotorPolicies.NoGoalProvided

  alias Monty.Frameworks.Models.Salience.MotorPolicy.{
    GoalCollocatedWithSensor,
    LookAtGoal
  }

  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.{GazeDirection, Rotation}

  @agent "agent_id_0"
  @sensor "view_finder"
  @identity Rotation.identity()

  # -- fixtures ------------------------------------------------------------

  defp state(options \\ []) do
    sensor_rotation = Keyword.get(options, :sensor_rotation, @identity)

    %{
      @agent => %AgentState{
        sensors: %{
          @sensor => %SensorState{position: [0.0, 0.0, 0.0], rotation: sensor_rotation}
        },
        position: Keyword.get(options, :agent_position, [0.0, 0.0, 0.0]),
        rotation: Keyword.get(options, :agent_rotation, @identity)
      }
    }
  end

  # A goal somewhere in the world, looked at by nobody in particular.
  defp goal(location) do
    {:ok, goal} =
      Goal.new(
        location: location,
        morphological_features: %{
          "pose_vectors" => %GazeDirection{
            value: [[0.0, 0.0, -1.0], [nil, nil, nil], [nil, nil, nil]]
          }
        },
        sender_id: "LM_0",
        sender_type: :gsg
      )

    goal
  end

  defp policy do
    LookAtGoal.new(agent_id: @agent, sensor_id: @sensor)
  end

  defp step(policy, options \\ []) do
    LookAtGoal.call(
      policy,
      Keyword.get(options, :context, Context.new(0)),
      nil,
      Keyword.get(options, :state, state()),
      nil,
      Keyword.get(options, :goal)
    )
  end

  defp angles(result) do
    %MotorPolicyResult{actions: [turn, look]} = result
    assert %TurnLeft{} = turn
    assert %LookUp{} = look

    {turn.rotation_degrees, look.rotation_degrees}
  end

  # -- aiming --------------------------------------------------------------

  describe "looking at where the goal is" do
    test "a goal straight ahead needs no turn and no pitch" do
      {yaw, pitch} = angles(elem(step(policy(), goal: goal([0.0, 0.0, -1.0])), 0))

      assert_in_delta yaw, 0.0, 1.0e-12
      assert_in_delta pitch, 0.0, 1.0e-12
    end

    test "a goal to the agent's left turns the agent that way, in degrees" do
      # Looking left is a negative turn about the vertical axis in Monty's
      # frames: 45 degrees left of straight ahead.
      {yaw, _pitch} = angles(elem(step(policy(), goal: goal([-1.0, 0.0, -1.0])), 0))

      assert_in_delta yaw, 45.0, 1.0e-9
    end

    test "a goal above the horizon pitches the sensor up by its elevation" do
      {_yaw, pitch} = angles(elem(step(policy(), goal: goal([0.0, 1.0, -1.0])), 0))

      assert_in_delta pitch, 45.0, 1.0e-9
    end

    test "a goal below the horizon pitches the sensor down, as a negative look up" do
      {_yaw, pitch} = angles(elem(step(policy(), goal: goal([0.0, -1.0, -1.0])), 0))

      assert_in_delta pitch, -45.0, 1.0e-9
    end

    test "a sensor that already looks up only has the difference left to do" do
      {:ok, pitched} = Rotation.from_axis_angle([1.0, 0.0, 0.0], :math.pi() / 9)

      {_yaw, pitch} =
        angles(
          elem(
            step(policy(), goal: goal([0.0, 1.0, -1.0]), state: state(sensor_rotation: pitched)),
            0
          )
        )

      assert_in_delta pitch, 45.0 - 20.0, 1.0e-9
    end

    test "it measures from the agent, not from the world's origin" do
      # Seen from the origin this goal is 63 degrees to the right; seen from a
      # metre towards it, it is 45 — so the agent's position has to be subtracted.
      {from_a_metre_away, _pitch} =
        angles(
          elem(
            step(policy(),
              goal: goal([2.0, 0.0, -1.0]),
              state: state(agent_position: [1.0, 0.0, 0.0])
            ),
            0
          )
        )

      assert_in_delta from_a_metre_away, -45.0, 1.0e-9
    end

    test "the actions are made for its own agent and sensor's agent" do
      %MotorPolicyResult{actions: [turn, look]} =
        elem(step(policy(), goal: goal([1.0, 0.0, -1.0])), 0)

      assert turn.agent_id == @agent
      assert look.agent_id == @agent
    end
  end

  # -- refusals ------------------------------------------------------------

  describe "when there is nothing to look at" do
    test "no goal raises, because the selector that called it decided there was one" do
      assert_raise NoGoalProvided, fn -> step(policy(), goal: nil) end
    end

    test "no goal is a warning and no action when runtime errors are suppressed" do
      context = %{Context.new(0) | suppress_runtime_errors: true}

      assert {%MotorPolicyResult{actions: []}, _policy} =
               step(policy(), goal: nil, context: context)
    end

    test "a goal at the sensor raises, because a zero vector has no azimuth" do
      assert_raise GoalCollocatedWithSensor, fn ->
        step(policy(), goal: goal([0.0, 0.0, 0.0]))
      end
    end

    test "a goal at the sensor is a warning and no action when errors are suppressed" do
      context = %{Context.new(0) | suppress_runtime_errors: true}

      assert {%MotorPolicyResult{actions: []}, _policy} =
               step(policy(), goal: goal([0.0, 0.0, 0.0]), context: context)
    end
  end

  describe "what it remembers" do
    test "which body and which sensor it aims" do
      assert LookAtGoal.state_dict(policy()) == %{agent_id: @agent, sensor_id: @sensor}
    end

    test "nothing to reset: where the sensor points is the world's business" do
      assert LookAtGoal.reset(policy()) == policy()
    end
  end
end
