defmodule Monty.Frameworks.Models.MotorPolicies.BasePolicyTest do
  use ExUnit.Case, async: true

  alias Monty.Context
  alias Monty.Frameworks.Actions.LookDown
  alias Monty.Frameworks.Models.MotorPolicies.BasePolicy
  alias Monty.Frameworks.Models.MotorSystemState.AgentState

  @agent "agent_id_0"
  @action %LookDown{agent_id: @agent, rotation_degrees: 30.0}

  @state %{
    @agent => %AgentState{sensors: %{}, position: [0.0, 0.0, 0.0], rotation: nil}
  }

  defp policy, do: BasePolicy.new(action_sampler: fn @agent -> @action end, agent_id: @agent)

  defp step(policy, goal \\ nil) do
    BasePolicy.call(policy, Context.new(0), %{}, @state, nil, goal)
  end

  describe "taking a step" do
    test "takes the one action its sampler chose" do
      assert {%{actions: [@action]}, _policy} = step(policy())
    end

    test "asks the sampler for its own agent" do
      sampler = fn agent_id -> %LookDown{agent_id: agent_id, rotation_degrees: 1.0} end
      policy = BasePolicy.new(action_sampler: sampler, agent_id: "other_agent")

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

  describe "what it remembers" do
    test "nothing, because a sample depends on the sampler and not on the episode" do
      assert BasePolicy.state_dict(policy()) == %{}
    end

    test "and resetting it changes nothing" do
      policy = policy()
      assert BasePolicy.reset(policy) == policy
    end
  end
end
