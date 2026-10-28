defmodule Monty.Frameworks.Models.MotorPolicies.JumpToGoalTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Context
  alias Monty.Frameworks.Actions.{SetAgentPose, SetSensorRotation}
  alias Monty.Frameworks.Models.MotorPolicies.{JumpToGoal, MotorPolicyResult}
  alias Monty.Frameworks.Models.MotorPolicies.NoGoalProvided
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.{GazeDirection, Rotation, SurfacePoseVectors}

  @agent "agent_id_0"
  @identity Rotation.identity()

  # -- fixtures ------------------------------------------------------------

  defp state(position \\ [0.1, 0.2, 0.3]) do
    %{
      @agent => %AgentState{
        sensors: %{
          "patch" => %SensorState{position: [0.0, 0.0, 0.0], rotation: @identity},
          "view_finder" => %SensorState{position: [0.0, 0.0, 0.0], rotation: @identity}
        },
        position: position,
        rotation: @identity
      }
    }
  end

  # A goal half a metre along -x, looking that way.
  defp goal do
    {:ok, goal} =
      Goal.new(
        location: [-0.5, 0.0, 0.0],
        morphological_features: %{
          "pose_vectors" => %GazeDirection{
            value: [[-1.0, 0.0, 0.0], [nil, nil, nil], [nil, nil, nil]]
          }
        },
        sender_id: "LM_0",
        sender_type: :gsg
      )

    goal
  end

  defp percept(on_object?) do
    {:ok, message} =
      Message.new(
        location: [0.0, 0.0, 0.0],
        morphological_features: %{
          "pose_vectors" =>
            SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
          "pose_fully_defined" => true,
          "on_object" => on_object?
        },
        non_morphological_features: %{},
        confidence: 1.0,
        pass_message: true,
        process_features_in_lm: true,
        sender_id: "patch",
        sender_type: :sm
      )

    message
  end

  defp policy, do: JumpToGoal.new(agent_id: @agent, sensor_id: "view_finder")

  defp step(policy, options \\ []) do
    JumpToGoal.call(
      policy,
      Keyword.get(options, :context, Context.new(0)),
      nil,
      Keyword.get(options, :state, state()),
      Keyword.get(options, :percept, percept(true)),
      Keyword.get(options, :goal, goal())
    )
  end

  # -- jumping -------------------------------------------------------------

  describe "jumping to a goal" do
    test "it moves the agent to the goal and points it along the goal's gaze" do
      {%MotorPolicyResult{actions: [set_pose, sensor_rotation], status: status}, policy} =
        step(policy())

      assert %SetAgentPose{location: [-0.5, 0.0, 0.0]} = set_pose

      # The goal looks along -x, so the agent turns a quarter turn about the
      # vertical axis and does not roll.
      {:ok, expected} = Rotation.from_euler_degrees([0.0, 90.0, 0.0])
      assert set_pose.rotation_quat == Rotation.to_quaternion(expected)

      assert %SetSensorRotation{rotation_quat: {1.0, 0.0, 0.0, 0.0}} = sensor_rotation
      assert status == :in_progress
      assert policy.is_jumping
    end

    test "it remembers the way back, before it moves" do
      {_result, policy} = step(policy(), state: state([0.4, 0.5, 0.6]))

      assert [%SetAgentPose{location: [0.4, 0.5, 0.6]} = back, %SetSensorRotation{}] =
               policy.undo_jump_actions

      assert back.rotation_quat == Rotation.to_quaternion(@identity)
    end
  end

  # -- judging the jump ----------------------------------------------------

  describe "judging where the jump landed" do
    test "on the object it asks for nothing, and is ready for the next goal" do
      {_result, jumped} = step(policy())

      {%MotorPolicyResult{actions: [], status: :ready}, policy} =
        step(jumped, percept: percept(true), goal: nil)

      refute policy.is_jumping
    end

    test "off the object it undoes the jump" do
      {_result, jumped} = step(policy())

      {%MotorPolicyResult{actions: actions}, policy} =
        step(jumped, percept: percept(false), goal: nil)

      assert actions == jumped.undo_jump_actions
      refute policy.is_jumping
    end

    test "a jump that landed well can be followed by the next jump in one step" do
      {_result, jumped} = step(policy())

      {%MotorPolicyResult{actions: [%SetAgentPose{}, %SetSensorRotation{}]}, policy} =
        step(jumped)

      assert policy.is_jumping
    end
  end

  # -- when there is no goal -----------------------------------------------

  describe "when there is no goal" do
    test "it refuses, because the selector that called it decided there was one" do
      assert_raise NoGoalProvided, fn -> step(policy(), goal: nil) end
    end

    test "unless the run was told to suppress runtime errors" do
      context = %{Context.new(0) | suppress_runtime_errors: true}

      assert {%MotorPolicyResult{actions: []}, _policy} =
               step(policy(), goal: nil, context: context)
    end
  end

  describe "when the sensors disagree about their orientation" do
    test "it refuses to plan a jump it cannot undo" do
      {:ok, turned} = Rotation.from_euler_degrees([0.0, 0.0, 45.0])

      a_state = %{
        @agent => %AgentState{
          sensors: %{
            "patch" => %SensorState{position: [0.0, 0.0, 0.0], rotation: @identity},
            "view_finder" => %SensorState{position: [0.0, 0.0, 0.0], rotation: turned}
          },
          position: [0.0, 0.0, 0.0],
          rotation: @identity
        }
      }

      assert_raise RuntimeError, ~r/not identical/, fn -> step(policy(), state: a_state) end
    end
  end

  # -- what it remembers ---------------------------------------------------

  describe "what it remembers" do
    test "the jump in flight" do
      {_result, jumped} = step(policy())

      assert %{is_jumping: true, pre_jump_state: %AgentState{}, undo_jump_actions: [_, _]} =
               JumpToGoal.state_dict(jumped)
    end

    test "and nothing, once the jump has been judged" do
      {_result, jumped} = step(policy())
      {_result, landed} = step(jumped, percept: percept(true), goal: nil)

      assert JumpToGoal.state_dict(landed).is_jumping == false
      assert JumpToGoal.state_dict(landed).undo_jump_actions == []
    end

    test "resetting forgets the jump" do
      {_result, jumped} = step(policy())

      refute JumpToGoal.reset(jumped).is_jumping
    end
  end
end
