defmodule Monty.Frameworks.Models.MotorPolicySelectors.DistantPolicySelectorTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Goal
  alias Monty.Context
  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Actions.{MoveForward, SetAgentPose, TurnLeft}
  alias Monty.Frameworks.Models.MotorPolicies.{BasePolicy, JumpToGoal, MotorPolicyResult}
  alias Monty.Frameworks.Models.MotorPolicySelectors.DistantPolicySelector
  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Frameworks.Models.Salience.MotorPolicy.LookAtGoal
  alias Monty.Geometry.{GazeDirection, Rotation, SurfacePoseVectors}

  @agent "agent_id_0"
  @sensor "view_finder"
  @identity Rotation.identity()

  # -- fixtures ------------------------------------------------------------

  defp state do
    %{
      @agent => %AgentState{
        sensors: %{
          @sensor => %SensorState{position: [0.0, 0.0, 0.0], rotation: @identity}
        },
        position: [0.0, 0.0, 0.0],
        rotation: @identity
      }
    }
  end

  defp percept(on_object?) do
    {:ok, message} =
      Monty.Cmp.Message.new(
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

  # A goal half a metre along -x, proposed by whoever asked for it.
  defp goal(sender_type, confidence \\ 0.9) do
    {:ok, goal} =
      Goal.new(
        location: [-0.5, 0.0, 0.0],
        morphological_features: %{
          "pose_vectors" => %GazeDirection{
            value: [[-1.0, 0.0, 0.0], [nil, nil, nil], [nil, nil, nil]]
          }
        },
        sender_id: sender_id(sender_type),
        sender_type: sender_type,
        confidence: confidence
      )

    goal
  end

  defp sender_id(:gsg), do: "LM_0"
  defp sender_id(:sm), do: @sensor

  defp default_policy do
    BasePolicy.new(
      agent_id: @agent,
      action_sampler: ConstantSampler.new(actions: [MoveForward], translation_distance: 0.05)
    )
  end

  defp selector do
    DistantPolicySelector.new(
      jump_to_goal: JumpToGoal.new(agent_id: @agent, sensor_id: @sensor),
      look_at_goal: LookAtGoal.new(agent_id: @agent, sensor_id: @sensor),
      default: default_policy()
    )
  end

  defp step(selector, options) do
    DistantPolicySelector.call(
      selector,
      Context.new(0),
      nil,
      Keyword.get(options, :state, state()),
      Keyword.get(options, :percept, percept(true)),
      Keyword.get(options, :goals, [])
    )
  end

  # -- choosing ------------------------------------------------------------

  describe "which policy a step goes to" do
    test "a learning module's goal makes the agent jump" do
      {%MotorPolicyResult{actions: [%SetAgentPose{}, _sensor_rotation], status: status}, selector} =
        step(selector(), goals: [goal(:gsg)])

      assert status == :in_progress
      assert selector.is_jumping
      assert selector.selected_policies == [JumpToGoal]
    end

    test "a sensor module's goal makes the agent look" do
      {%MotorPolicyResult{actions: [%TurnLeft{} | _]} = result, selector} =
        step(selector(), goals: [goal(:sm)])

      assert result.status == :ready
      refute selector.is_jumping
      assert selector.selected_policies == [LookAtGoal]
    end

    test "with no goals it asks the default policy, which is told nothing" do
      {%MotorPolicyResult{actions: [%MoveForward{}]}, selector} =
        step(selector(), goals: [])

      assert selector.selected_policies == [BasePolicy]
      assert selector.selected_goals == [nil]
    end

    test "a learning module's goal wins over a sensor module's" do
      {_result, selector} = step(selector(), goals: [goal(:sm), goal(:gsg)])

      assert selector.selected_policies == [JumpToGoal]
    end

    test "of each kind, the most confident goal is the one pursued" do
      {_result, selector} =
        step(selector(), goals: [goal(:gsg, 0.2), goal(:gsg, 0.8)])

      assert [%Goal{confidence: 0.8}] = selector.selected_goals
    end
  end

  # -- a jump in flight ----------------------------------------------------

  describe "while a jump is in flight" do
    test "the jump is judged before anything else is considered" do
      {_result, jumped} = step(selector(), goals: [goal(:gsg)])

      {%MotorPolicyResult{actions: actions}, selector} =
        step(jumped, percept: percept(false), goals: [])

      # Off the object, so the jump is undone — not a look, not a wander.
      assert [%SetAgentPose{}, _sensor_rotation] = actions
      assert selector.selected_policies == [JumpToGoal, JumpToGoal]
      refute selector.is_jumping
    end

    test "a jump that landed well leaves the step free for the default policy" do
      {_result, jumped} = step(selector(), goals: [goal(:gsg)])

      {%MotorPolicyResult{actions: [%MoveForward{}]}, selector} =
        step(jumped, percept: percept(true), goals: [])

      assert selector.selected_policies == [JumpToGoal, BasePolicy]
      refute selector.is_jumping
    end

    test "a jump that landed well can start the next jump in the same step" do
      {_result, jumped} = step(selector(), goals: [goal(:gsg)])

      {%MotorPolicyResult{status: status}, selector} = step(jumped, goals: [goal(:gsg)])

      assert status == :in_progress
      assert selector.is_jumping
      assert selector.selected_policies == [JumpToGoal, JumpToGoal]
    end
  end

  # -- what it remembers ---------------------------------------------------

  describe "what it remembers" do
    test "which policy and which goal each step chose" do
      {_result, selector} = step(selector(), goals: [goal(:sm)])
      {_result, selector} = step(selector, goals: [])

      assert selector.selected_policies == [LookAtGoal, BasePolicy]
      assert [%Goal{sender_type: :sm}, nil] = selector.selected_goals
    end

    test "each policy's own record, not a summary of it" do
      {_result, selector} = step(selector(), goals: [goal(:gsg)])

      assert %{jump_to_goal: %{is_jumping: true}, look_at_goal: %{}, default: %{}} =
               DistantPolicySelector.state_dict(selector)
    end

    test "resetting starts every policy over" do
      {_result, jumped} = step(selector(), goals: [goal(:gsg)])

      reset = DistantPolicySelector.reset(jumped)

      refute reset.is_jumping
      assert reset.selected_policies == []
      assert reset.selected_goals == []
      refute DistantPolicySelector.state_dict(reset).jump_to_goal.is_jumping
    end
  end
end
