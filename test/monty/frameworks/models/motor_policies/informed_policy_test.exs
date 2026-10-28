defmodule Monty.Frameworks.Models.MotorPolicies.InformedPolicyTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Context
  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Actions.{SetAgentPose, SetSensorRotation, TurnLeft}
  alias Monty.Frameworks.Models.MotorPolicies.{InformedPolicy, MotorPolicyResult}
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Geometry.{GazeDirection, Rotation, SurfacePoseVectors}

  @agent "agent_id_0"
  @view_finder "view_finder"
  @identity Rotation.identity()

  # -- fixtures ------------------------------------------------------------

  defp state(position \\ [0.1, 0.2, 0.3]) do
    %{
      @agent => %AgentState{
        sensors: %{"patch" => %SensorState{position: [0.0, 0.0, 0.0], rotation: @identity}},
        position: position,
        rotation: @identity
      }
    }
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

  # A world that reports one depth everywhere in the view finder.
  defp observations(depth) do
    %{@agent => %{@view_finder => %{"depth" => [[depth, depth], [depth, depth]]}}}
  end

  # A goal 20 cm along x, looking back towards the agent along -x.
  defp goal do
    {:ok, goal} =
      Goal.new(
        location: [0.2, 0.0, 0.0],
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

  defp policy(options \\ []) do
    InformedPolicy.new(
      Keyword.merge(
        [
          agent_id: @agent,
          action_sampler: ConstantSampler.new(actions: [TurnLeft], rotation_degrees: 5.0)
        ],
        options
      )
    )
  end

  defp step(policy, options \\ []) do
    InformedPolicy.call(
      policy,
      Context.new(0),
      Keyword.get(options, :observations),
      Keyword.get(options, :state, state()),
      Keyword.get(options, :percept, percept(true)),
      Keyword.get(options, :goal)
    )
  end

  # -- staying on the object -----------------------------------------------

  describe "while the sensor is on the object" do
    test "takes the sampled action" do
      assert {%MotorPolicyResult{actions: [%TurnLeft{rotation_degrees: 5.0}]}, _policy} =
               step(policy())
    end

    test "remembers what would undo it" do
      assert {_result, policy} = step(policy())
      assert policy.undo_action == %TurnLeft{agent_id: @agent, rotation_degrees: -5.0}
    end
  end

  describe "when the sensor has left the object" do
    defp after_a_sample do
      {_result, policy} = step(policy())
      policy
    end

    test "takes the opposite of what it last did" do
      assert {%MotorPolicyResult{actions: [%TurnLeft{rotation_degrees: -5.0}]}, _policy} =
               step(after_a_sample(), percept: percept(false))
    end

    test "remembers the opposite of the opposite, so it can come back again" do
      {_result, policy} = step(after_a_sample(), percept: percept(false))
      assert {_result, policy} = step(policy, percept: percept(false))

      assert policy.undo_action == %TurnLeft{agent_id: @agent, rotation_degrees: -5.0}
    end

    test "stays put when it has never moved onto the object" do
      assert {%MotorPolicyResult{actions: []}, _policy} = step(policy(), percept: percept(false))
    end
  end

  # -- jumping --------------------------------------------------------------

  describe "jumping to a goal" do
    defp jumping_policy, do: policy(use_goal_driven_actions: true)

    test "puts the agent at the goal, facing along the goal's direction" do
      assert {%MotorPolicyResult{actions: actions}, policy} =
               step(jumping_policy(), observations: observations(0.5), goal: goal())

      assert [%SetAgentPose{} = pose, %SetSensorRotation{}] = actions
      assert pose.location == [0.2, 0.0, 0.0]

      # Looking along -x means a quarter turn about y.
      assert_in_delta elem(pose.rotation_quat, 0), :math.sqrt(0.5), 1.0e-9
      assert_in_delta elem(pose.rotation_quat, 1), 0.0, 1.0e-9
      assert_in_delta elem(pose.rotation_quat, 2), :math.sqrt(0.5), 1.0e-9
      assert_in_delta elem(pose.rotation_quat, 3), 0.0, 1.0e-9

      assert policy.is_jumping
    end

    test "sets the sensors back to no rotation, because the jump moved them" do
      assert {%MotorPolicyResult{actions: [_pose, sensor]}, _policy} =
               step(jumping_policy(), observations: observations(0.5), goal: goal())

      assert sensor.rotation_quat == {1.0, 0.0, 0.0, 0.0}
    end

    test "remembers the pose it left, and the actions that would restore it" do
      assert {%MotorPolicyResult{actions: [_pose, _sensor]}, policy} =
               step(jumping_policy(), observations: observations(0.5), goal: goal())

      assert policy.pre_jump_state.position == [0.1, 0.2, 0.3]

      assert [%SetAgentPose{location: [0.1, 0.2, 0.3]}, %SetSensorRotation{}] =
               policy.undo_jump_actions
    end

    test "does not jump when no goal was proposed" do
      assert {%MotorPolicyResult{actions: [%TurnLeft{}]}, policy} =
               step(jumping_policy(), observations: observations(0.5))

      refute policy.is_jumping
    end

    test "samples as usual when jumping is not enabled" do
      assert {%MotorPolicyResult{actions: [%TurnLeft{}]}, _policy} =
               step(policy(), observations: observations(0.5), goal: goal())
    end
  end

  describe "the step after a jump" do
    defp after_a_jump do
      {_result, policy} =
        step(policy(use_goal_driven_actions: true), observations: observations(0.5), goal: goal())

      policy
    end

    test "carries on when the object is in view" do
      assert {%MotorPolicyResult{actions: [%TurnLeft{}]}, policy} =
               step(after_a_jump(), observations: observations(0.5))

      refute policy.is_jumping
      assert policy.pre_jump_state == nil
    end

    test "goes back when the jump landed in empty space" do
      assert {%MotorPolicyResult{
                actions: [%SetAgentPose{location: [0.1, 0.2, 0.3]}, %SetSensorRotation{}]
              }, policy} = step(after_a_jump(), observations: observations(1.5))

      assert policy.is_undoing_jump
    end

    test "checks that going back arrived, then carries on" do
      {_result, policy} = step(after_a_jump(), observations: observations(1.5))

      assert {%MotorPolicyResult{actions: [%TurnLeft{}]}, policy} =
               step(policy, observations: observations(1.5))

      refute policy.is_jumping
      refute policy.is_undoing_jump
    end

    test "says so when going back did not arrive" do
      {_result, policy} = step(after_a_jump(), observations: observations(1.5))

      assert_raise RuntimeError, ~r/undo jump left the agent/, fn ->
        step(policy, observations: observations(1.5), state: state([9.0, 9.0, 9.0]))
      end
    end
  end

  describe "starting over" do
    test "forgets the action to undo and any jump in flight" do
      {_result, policy} = step(policy())
      policy = InformedPolicy.reset(policy)

      assert policy.undo_action == nil
      refute policy.is_jumping
      assert policy.pre_jump_state == nil
    end
  end
end
