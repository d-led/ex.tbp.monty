defmodule Monty.Frameworks.Models.MotorPolicies.BasePolicyTest do
  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Actions.ActionSamplers.ConstantSampler
  alias Monty.Frameworks.Actions.{LookDown, MoveForward}
  alias Monty.Frameworks.Models.MotorPolicies.BasePolicy
  alias Monty.Frameworks.Models.MotorSystemState.AgentState

  @agent "agent_id_0"
  @action %LookDown{agent_id: @agent, rotation_degrees: 30.0}

  @state %{
    @agent => %AgentState{sensors: %{}, position: [0.0, 0.0, 0.0], rotation: nil}
  }

  defp sampler, do: ConstantSampler.new(actions: [LookDown], rotation_degrees: 30.0)

  defp policy, do: BasePolicy.new(action_sampler: sampler(), agent_id: @agent)

  # A sampler that can make either of two actions, so that a stream which is
  # being threaded shows up in what the policy does.
  defp wandering_policy do
    BasePolicy.new(
      action_sampler: ConstantSampler.new(actions: [LookDown, MoveForward]),
      agent_id: @agent
    )
  end

  defp step(policy, goal \\ nil) do
    BasePolicy.call(policy, Context.new(0), %{}, @state, nil, goal)
  end

  defp actions_over(policy, steps) do
    {actions, _policy} =
      Enum.map_reduce(1..steps, policy, fn _step, policy ->
        {%{actions: [action]}, policy} = step(policy)
        {action, policy}
      end)

    actions
  end

  describe "taking a step" do
    test "takes the one action its sampler chose" do
      assert {%{actions: [@action]}, _policy} = step(policy())
    end

    test "asks the sampler for its own agent" do
      policy = BasePolicy.new(action_sampler: sampler(), agent_id: "other_agent")

      assert {%{actions: [%LookDown{agent_id: "other_agent"}]}, _policy} = step(policy)
    end

    test "does not ask the learning modules to sit the step out" do
      assert {%{motor_only_step: false}, _policy} = step(policy())
    end

    test "takes the same action whether or not it was given a goal" do
      goal = %Monty.Cmp.Goal{sender_id: "LM_0", sender_type: :gsg, confidence: 0.9}

      assert {%{actions: [@action]}, _policy} = step(policy(), goal)
    end
  end

  describe "the stream it draws from" do
    test "keeps drawing where the last step left off, so it can wander" do
      actions = actions_over(wandering_policy(), 100)

      assert actions |> Enum.map(& &1.__struct__) |> Enum.uniq() |> length() > 1
    end

    test "two policies on the same episode draw the same actions" do
      assert actions_over(wandering_policy(), 10) == actions_over(wandering_policy(), 10)
    end

    test "resetting starts a new stream, so it draws as a fresh policy does" do
      {_result, used} = step(wandering_policy())

      assert actions_over(BasePolicy.reset(used), 10) == actions_over(wandering_policy(), 10)
    end
  end

  describe "what it remembers" do
    test "nothing, because what it draws is not worth reporting" do
      assert BasePolicy.state_dict(policy()) == %{}
    end
  end
end
