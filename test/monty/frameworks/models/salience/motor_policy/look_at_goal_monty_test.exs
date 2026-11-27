defmodule Monty.Frameworks.Models.Salience.MotorPolicy.LookAtGoalMontyTest do
  @moduledoc """
  Monty's own cases for `LookAtGoal`, translated.

  Each test names the case in
  `tests/unit/frameworks/models/salience/motor_policy_test.py` it translates.
  Monty's class states its simplifications outright and they are kept: the agent
  is at the origin with the identity rotation, the sensor is collocated with it
  and also unrotated, so the only thing that can turn the forward vector is the
  action pair under test.

  Monty's last case draws its goals from `nonzero_magnitude_vectors`. Here they
  are four fixed directions — one per axis and two off it, all non-zero — because
  the claim is about the geometry, not about how many points were drawn.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.Goal
  alias Monty.Context
  alias Monty.Frameworks.Actions.{LookUp, TurnLeft}
  alias Monty.Frameworks.Models.MotorPolicies.{MotorPolicyResult, NoGoalProvided}
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}

  alias Monty.Frameworks.Models.Salience.MotorPolicy.{
    GoalCollocatedWithSensor,
    LookAtGoal
  }

  alias Monty.Geometry.Rotation

  @agent "agent_id_0"
  @sensor "sensor_id_0"
  @tolerance 1.0e-6

  # Monty's convention: right, up, backward — so forward is -z.
  @forward [0.0, 0.0, -1.0]

  defp state do
    %{
      @agent => %AgentState{
        sensors: %{
          @sensor => %SensorState{position: [0.0, 0.0, 0.0], rotation: Rotation.identity()}
        },
        position: [0.0, 0.0, 0.0],
        rotation: Rotation.identity()
      }
    }
  end

  defp policy, do: LookAtGoal.new(agent_id: @agent, sensor_id: @sensor)

  defp goal(location) do
    {:ok, goal} =
      Goal.new(
        location: location,
        morphological_features: %{
          "pose_vectors" => %Monty.Geometry.GazeDirection{
            value: [[0.0, 0.0, -1.0], [nil, nil, nil], [nil, nil, nil]]
          }
        },
        sender_id: "test",
        sender_type: :sm
      )

    goal
  end

  defp step(policy, options) do
    LookAtGoal.call(
      policy,
      Keyword.get(options, :context, Context.new(42)),
      nil,
      state(),
      nil,
      Keyword.get(options, :goal)
    )
  end

  defp quiet_context, do: Context.new(42, suppress_runtime_errors: true)

  defp normalise([x, y, z]) do
    magnitude = :math.sqrt(x * x + y * y + z * z)
    [x / magnitude, y / magnitude, z / magnitude]
  end

  # test_raises_error_if_no_goal_is_provided_if_not_suppressing_runtime_errors
  test "no goal is an error unless the run suppresses runtime errors" do
    assert_raise NoGoalProvided, fn -> step(policy(), goal: nil) end
  end

  # test_returns_empty_result_if_no_goal_is_provided_if_suppressing_runtime_errors
  @tag :capture_log
  test "no goal is no action when the run suppresses runtime errors" do
    {%MotorPolicyResult{actions: actions}, _policy} =
      step(policy(), context: quiet_context(), goal: nil)

    assert actions == []
  end

  # test_raises_error_if_goal_collocated_with_sensor_and_not_suppressing_runtime_errors
  test "a goal at the sensor is an error unless the run suppresses runtime errors" do
    assert_raise GoalCollocatedWithSensor, fn ->
      step(policy(), goal: goal([0.0, 0.0, 0.0]))
    end
  end

  # test_returns_empty_result_if_goal_collocated_with_sensor_and_suppressing_runtime_errors
  @tag :capture_log
  test "a goal at the sensor is no action when the run suppresses runtime errors" do
    {%MotorPolicyResult{actions: actions}, _policy} =
      step(policy(), context: quiet_context(), goal: goal([0.0, 0.0, 0.0]))

    assert actions == []
  end

  # test_returns_turn_left_and_look_up_oriented_at_the_goal
  test "a turn and a pitch, applied to the forward vector, point it at the goal" do
    for goal_xyz <- [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [1.0, 2.0, -3.0], [-4.0, -5.0, 6.0]] do
      {%MotorPolicyResult{actions: [first, second]}, _policy} =
        step(policy(), goal: goal(goal_xyz))

      assert %TurnLeft{} = turn_left = first
      assert %LookUp{} = look_up = second
      assert abs(look_up.rotation_degrees) <= look_up.constraint_degrees

      {:ok, rotation} =
        Rotation.from_euler_degrees([
          look_up.rotation_degrees,
          turn_left.rotation_degrees,
          0.0
        ])

      actuated = Rotation.apply(rotation, @forward)
      expected = normalise(goal_xyz)

      assert Enum.zip(expected, actuated)
             |> Enum.all?(fn {wanted, got} -> abs(wanted - got) <= @tolerance end),
             "for a goal at #{inspect(goal_xyz)} the pair turns the forward vector to " <>
               "#{inspect(actuated)} instead of #{inspect(expected)}"
    end
  end
end
