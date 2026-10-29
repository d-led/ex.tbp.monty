defmodule Monty.Frameworks.Models.MotorPolicySelectors.SinglePolicySelectorTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Goal
  alias Monty.Context
  alias Monty.Frameworks.Models.MotorPolicySelectors.SinglePolicySelector
  alias Monty.Test.RecordingPolicy

  defp goal(confidence) do
    %Goal{sender_id: "LM_0", sender_type: :gsg, confidence: confidence, location: [0.0, 0.0, 0.0]}
  end

  # A policy that says what it was asked about, which is the only thing a
  # selector decides.
  defp reporting_policy, do: RecordingPolicy.new(actions: [:asked])

  defp call(selector, goals) do
    SinglePolicySelector.call(selector, Context.new(0), nil, %{}, nil, goals)
  end

  defp asked_about(selector), do: selector.policy.asked_about

  describe "choosing a goal" do
    test "gives the policy the goal the run believes in most" do
      selector = SinglePolicySelector.new(policy: reporting_policy())
      believed = goal(0.9)

      {_result, selector} = call(selector, [goal(0.4), believed])

      assert asked_about(selector) == [believed]
    end

    test "gives equal confidences to the first, as a stable sort does" do
      selector = SinglePolicySelector.new(policy: reporting_policy())
      first = goal(0.5)

      {_result, selector} = call(selector, [first, goal(0.5)])

      assert asked_about(selector) == [first]
    end

    test "asks the policy anyway when nothing was proposed" do
      selector = SinglePolicySelector.new(policy: reporting_policy())

      {_result, selector} = call(selector, [])

      assert asked_about(selector) == [nil]
    end
  end

  describe "recording what it chose" do
    test "keeps one goal per step, including the steps with none" do
      selector = SinglePolicySelector.new(policy: reporting_policy())
      believed = goal(0.9)

      {_result, selector} = call(selector, [believed])
      {_result, selector} = call(selector, [])

      assert SinglePolicySelector.state_dict(selector) == %{
               policy: %{asked_about: [believed, nil]},
               selected_goals: [believed, nil]
             }
    end

    test "starts the record over when the episode does, and the policy with it" do
      selector = SinglePolicySelector.new(policy: reporting_policy())
      {_result, selector} = call(selector, [goal(0.9)])

      reset = SinglePolicySelector.reset(selector)

      assert reset.selected_goals == []
      assert reset.policy.asked_about == []
      assert reset.policy.resets == 1
    end

    test "can be handed a record to carry on from" do
      believed = goal(0.7)
      selector = SinglePolicySelector.new(policy: reporting_policy(), selected_goals: [believed])

      {_result, selector} = call(selector, [goal(0.2)])

      assert [^believed, %Goal{confidence: 0.2}] = selector.selected_goals
    end
  end
end
