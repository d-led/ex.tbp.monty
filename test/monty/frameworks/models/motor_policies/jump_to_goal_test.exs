defmodule Monty.Frameworks.Models.MotorPolicies.JumpToGoalTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.{Goal, Message}
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
          },
          "pose_fully_defined" => true
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
      Keyword.get(options, :context, Monty.EpisodeStream.context(0)),
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
      context = %{Monty.EpisodeStream.context(0) | suppress_runtime_errors: true}

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

  # -- Monty's own cases ---------------------------------------------------

  # Monty's `JumpToGoalTest`, driven through the same `call/6` every other case
  # here uses. Its goals are `Mock`s whose `pose_vectors` is a `GazeDirection`;
  # a goal here is a real `Goal` carrying the same direction, and its
  # `get_on_object` is the percept's own `on_object` feature.
  describe "Monty's own cases" do
    # test_generates_actions_that_align_forward_axis_with_goal_direction
    test "the jump stands the agent at the goal, facing the way the goal looks" do
      for {location, direction} <- [
            {[0.5, 0.0, 0.0], [-1.0, 0.0, 0.0]},
            {[-0.25, 0.75, 0.1], [0.0, 0.0, -1.0]},
            {[0.0, 0.0, 0.4], [0.7071067811865475, 0.7071067811865475, 0.0]}
          ] do
        {%MotorPolicyResult{actions: [set_pose, sensor_rotation]}, _policy} =
          step(policy(), goal: goal_at(location, direction))

        assert %SetAgentPose{location: ^location} = set_pose

        # Forward is the body's own −z, which the jump lines up with the goal's
        # gaze (Monty's `-rotation.as_matrix()[:, 2]`).
        forward =
          set_pose.rotation_quat
          |> Rotation.from_quaternion()
          |> Rotation.apply([0.0, 0.0, -1.0])

        assert_vector(forward, direction)

        # The head is not turned by a jump.
        assert %SetSensorRotation{rotation_quat: {1.0, 0.0, 0.0, 0.0}} = sensor_rotation
      end
    end

    # test_returns_undo_actions_status_ready_if_undo_is_needed_regardless_of_new_goal
    test "a landing off the object is undone, whether a goal arrived or not" do
      for position <- [[0.0, 0.0, 0.0], [0.3, -0.2, 0.05]],
          rotation <- [@identity, turned(90.0)],
          sensor_rotation <- [@identity, turned(45.0)],
          goal <- [goal_at([0.0, 0.0, 0.0], [1.0, 0.0, 0.0]), nil] do
        before = state_with(position, rotation, sensor_rotation)
        {_result, jumped} = step(policy(), state: before)

        {%MotorPolicyResult{status: :ready, actions: [set_pose, set_sensor]}, _policy} =
          step(jumped, percept: percept(false), goal: goal)

        assert set_pose.location == position
        assert set_pose.rotation_quat == Rotation.to_quaternion(rotation)
        assert set_sensor.rotation_quat == Rotation.to_quaternion(sensor_rotation)
      end
    end

    # test_returns_new_jump_actions_status_in_progress_if_undo_is_not_needed_after_jump_and_goal_is_provided
    test "a landing on the object jumps again, to the goal that has arrived" do
      for {location, direction} <- [
            {[0.5, 0.0, 0.0], [-1.0, 0.0, 0.0]},
            {[-0.25, 0.75, 0.1], [0.0, 0.0, -1.0]}
          ] do
        {_result, jumped} = step(policy())

        {%MotorPolicyResult{status: :in_progress, actions: [set_pose, set_sensor]}, _policy} =
          step(jumped, percept: percept(true), goal: goal_at(location, direction))

        assert set_pose.location == location

        forward =
          set_pose.rotation_quat
          |> Rotation.from_quaternion()
          |> Rotation.apply([0.0, 0.0, -1.0])

        assert_vector(forward, direction)
        assert %SetSensorRotation{rotation_quat: {1.0, 0.0, 0.0, 0.0}} = set_sensor
      end
    end

    # test_returns_no_actions_status_ready_if_undo_is_not_needed_after_jump_and_goal_is_none
    test "a landing on the object with no goal asks for nothing at all" do
      {_result, jumped} = step(policy())

      assert {%MotorPolicyResult{status: :ready, actions: []}, _policy} =
               step(jumped, percept: percept(true), goal: nil)
    end
  end

  # -- Monty's fixtures ----------------------------------------------------

  # The goal Monty's `Mock` stands in for: a place, and the gaze it states in
  # its first pose vector — the other two rows undefined, as Monty's are.
  defp goal_at(location, direction) do
    {:ok, goal} =
      Goal.new(
        location: location,
        morphological_features: %{
          "pose_vectors" => %GazeDirection{
            value: [direction, [nil, nil, nil], [nil, nil, nil]]
          },
          "pose_fully_defined" => true
        },
        sender_id: "LM_0",
        sender_type: :gsg
      )

    goal
  end

  defp state_with(position, rotation, sensor_rotation) do
    %{
      @agent => %AgentState{
        sensors: %{
          "patch" => %SensorState{position: [0.0, 0.0, 0.0], rotation: @identity},
          "view_finder" => %SensorState{position: [0.0, 0.0, 0.0], rotation: sensor_rotation}
        },
        position: position,
        rotation: rotation
      }
    }
  end

  defp turned(degrees) do
    {:ok, rotation} = Rotation.from_euler_degrees([0.0, degrees, 0.0])
    rotation
  end

  # Monty's `np.testing.assert_allclose(..., atol=DEFAULT_TOLERANCE)`.
  defp assert_vector(actual, expected) do
    for {mine, theirs} <- Enum.zip(actual, expected) do
      assert_in_delta mine, theirs, 1.0e-6
    end
  end
end
