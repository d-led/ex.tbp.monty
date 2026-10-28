defmodule Monty.Frameworks.Models.MotorPolicies.InformedPolicyRandomWalkTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Context
  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Actions.{MoveForward, TurnLeft}
  alias Monty.Frameworks.Models.MotorPolicies.{InformedPolicyRandomWalk, MotorPolicyResult}
  alias Monty.Geometry.SurfacePoseVectors

  @agent "agent_id_0"

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

  defp policy(options \\ []) do
    InformedPolicyRandomWalk.new(
      agent_id: @agent,
      action_sampler:
        ConstantSampler.new(
          actions: Keyword.get(options, :actions, [TurnLeft]),
          rotation_degrees: 5.0,
          translation_distance: 0.05
        )
    )
  end

  defp step(policy, options) do
    InformedPolicyRandomWalk.call(
      policy,
      Context.new(0),
      nil,
      Keyword.get(options, :state, %{}),
      Keyword.get(options, :percept, percept(true)),
      Keyword.get(options, :goal)
    )
  end

  defp action_of(policy, options \\ []) do
    {%MotorPolicyResult{actions: [action]}, policy} = step(policy, options)
    {action, policy}
  end

  describe "on the object" do
    test "it takes a sampled action" do
      {action, _policy} = action_of(policy())

      assert %TurnLeft{rotation_degrees: 5.0} = action
    end

    test "and remembers what would undo it" do
      {_action, policy} = action_of(policy())

      assert policy.undo_action == %TurnLeft{agent_id: @agent, rotation_degrees: -5.0}
    end

    test "a percept of nothing is a sensor that cannot tell, which counts as on" do
      {action, _policy} = action_of(policy(), percept: nil)

      assert %TurnLeft{} = action
    end

    test "the goal and the motor state make no difference" do
      {with_everything, _policy} =
        action_of(policy(),
          state: %{@agent => :something},
          goal: %Monty.Cmp.Goal{sender_id: "LM_0", sender_type: :gsg, confidence: 0.9}
        )

      {with_nothing, _policy} = action_of(policy())

      assert with_everything == with_nothing
    end
  end

  describe "off the object" do
    test "it steps back with the remembered action, without sampling" do
      {_action, policy} = action_of(policy())

      {action, _policy} = action_of(policy, percept: percept(false))

      assert action == %TurnLeft{agent_id: @agent, rotation_degrees: -5.0}
    end

    test "and flips it again, so the sensor walks back and forth on the edge" do
      {_action, policy} = action_of(policy())
      {first_back, policy} = action_of(policy, percept: percept(false))
      {second_back, _policy} = action_of(policy, percept: percept(false))

      assert %TurnLeft{rotation_degrees: -5.0} = first_back
      assert second_back == %TurnLeft{agent_id: @agent, rotation_degrees: 5.0}
    end

    test "with nothing remembered it asks for nothing" do
      {%MotorPolicyResult{actions: actions}, policy} = step(policy(), percept: percept(false))

      assert actions == []
      assert policy.undo_action == nil
    end

    test "the step back is never taken from a policy that cannot undo what it did" do
      # A sampler that made a MoveForward can be undone, so the walk survives a
      # sampler whose actions are all reversible ones.
      {action, policy} = action_of(policy(actions: [MoveForward]))

      assert %MoveForward{distance: 0.05} = action

      {back, _policy} = action_of(policy, percept: percept(false))
      assert %MoveForward{distance: -0.05} = back
    end
  end

  describe "what it remembers" do
    test "the action it would step back with" do
      {_action, policy} = action_of(policy())

      assert InformedPolicyRandomWalk.state_dict(policy) == %{
               undo_action: %TurnLeft{agent_id: @agent, rotation_degrees: -5.0}
             }
    end

    test "and resetting forgets it" do
      {_action, policy} = action_of(policy())

      assert InformedPolicyRandomWalk.reset(policy).undo_action == nil
    end
  end
end
