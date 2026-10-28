defmodule Monty.Frameworks.Models.MotorPolicies.NaiveScanPolicyTest do
  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Actions.{LookDown, LookUp, TurnLeft, TurnRight}
  alias Monty.Frameworks.Models.MotorPolicies.{MotorPolicyResult, NaiveScanPolicy}
  alias Monty.Frameworks.Models.MotorSystemState.AgentState

  @agent "agent_id_0"
  @amount 10.0

  @state %{
    @agent => %AgentState{sensors: %{}, position: [0.0, 0.0, 0.0], rotation: nil}
  }

  defp policy do
    NaiveScanPolicy.new(
      agent_id: @agent,
      fixed_amount: @amount,
      action_sampler: ConstantSampler.new(actions: [LookUp])
    )
  end

  defp step(policy, options \\ []) do
    NaiveScanPolicy.call(
      policy,
      Context.new(0),
      Keyword.get(options, :observations),
      Keyword.get(options, :state, @state),
      Keyword.get(options, :percept),
      Keyword.get(options, :goal)
    )
  end

  defp scan(policy, steps) do
    {actions, _policy} =
      Enum.map_reduce(1..steps, policy, fn _step, policy ->
        {%MotorPolicyResult{actions: [action]}, policy} = step(policy)
        {action, policy}
      end)

    actions
  end

  # How long each leg of the spiral is, in steps.
  defp leg_lengths(actions) do
    actions
    |> Enum.map(& &1.__struct__)
    |> Enum.chunk_by(& &1)
    |> Enum.map(&length/1)
  end

  describe "the spiral" do
    test "it goes up, left, down and right, in that order, for ever" do
      kinds = scan(policy(), 12) |> Enum.map(& &1.__struct__)

      assert kinds == [
               LookUp,
               TurnLeft,
               LookDown,
               LookDown,
               TurnRight,
               TurnRight,
               LookUp,
               LookUp,
               LookUp,
               TurnLeft,
               TurnLeft,
               TurnLeft
             ]
    end

    test "each leg is one step longer than the last, on every side" do
      # Monty's picture: 1 up, 1 left, 2 down, 2 right, 3 up, 3 left, ... — eight
      # legs is one full circuit of the square twice over.
      assert scan(policy(), 20) |> leg_lengths() == [1, 1, 2, 2, 3, 3, 4, 4]
    end

    test "every action turns by the same fixed amount" do
      amounts = scan(policy(), 8) |> Enum.map(& &1.rotation_degrees)

      assert amounts == Enum.map(1..8, fn _step -> @amount end)
    end

    test "the actions are made for its own agent" do
      agents = scan(policy(), 4) |> Enum.map(& &1.agent_id)

      assert agents == Enum.map(1..4, fn _step -> @agent end)
    end
  end

  describe "what it ignores" do
    test "the percept, the observations, the state and the goal change nothing" do
      without_anything = scan(policy(), 6)

      {with_everything, _policy} =
        Enum.map_reduce(1..6, policy(), fn _step, policy ->
          {%MotorPolicyResult{actions: [action]}, policy} =
            step(policy,
              observations: %{@agent => %{"view_finder" => %{"depth" => [[0.1]]}}},
              percept: :a_percept,
              goal: %Monty.Cmp.Goal{sender_id: "LM_0", sender_type: :gsg, confidence: 0.9}
            )

          {action, policy}
        end)

      assert with_everything == without_anything
    end

    test "the learning modules see every step: scanning is the point" do
      {%MotorPolicyResult{motor_only_step: motor_only}, _policy} = step(policy())

      refute motor_only
    end
  end

  describe "starting again" do
    test "resetting begins a new spiral, legs one step long" do
      used = scan(policy(), 8) |> length()
      assert used == 8

      {_actions, after_eight} =
        Enum.map_reduce(1..8, policy(), fn _step, policy ->
          {%MotorPolicyResult{actions: [action]}, policy} = step(policy)
          {action, policy}
        end)

      assert scan(NaiveScanPolicy.reset(after_eight), 3) |> leg_lengths() == [1, 1, 1]
    end

    test "nothing worth reporting: the spiral is fixed at construction" do
      assert NaiveScanPolicy.state_dict(policy()) == %{}
    end
  end
end
