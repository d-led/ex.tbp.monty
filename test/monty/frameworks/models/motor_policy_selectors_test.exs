defmodule Monty.Frameworks.Models.MotorPolicySelectorsTest do
  @moduledoc """
  Translations of Monty's `tests/unit/frameworks/models/motor_policy_selectors_test.py`.

  Monty's cases hand a selector `Mock()` policies and read the mock's call log
  and `return_value`; here a policy is a struct whose module answers, so the same
  facts are read off the policy itself (`AnsweringPolicy`'s `goals`) and off the
  selector's record (`selected_goals`), which is what this port keeps for the same
  reason.

  One case is listed rather than translated:
  `test_fixme_provide_motor_system_calls_fixme_provide_motor_system_on_policy`
  drives `fixme_provide_motor_system`, which this port does not have on purpose —
  a policy says in its result what it wants instead (`docs/monty-differences.md`
  §2.2).
  """
  use ExUnit.Case, async: true

  alias Monty.Cmp.Goal
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult
  alias Monty.Frameworks.Models.MotorPolicySelectors
  alias Monty.Frameworks.Models.MotorPolicySelectors.AnsweringPolicy
  alias Monty.Frameworks.Models.MotorPolicySelectors.DistantPolicySelector
  alias Monty.Frameworks.Models.MotorPolicySelectors.SinglePolicySelector

  @ready %MotorPolicyResult{actions: [:one], status: :ready}
  @in_progress %MotorPolicyResult{actions: [:one, :two], status: :in_progress}
  @no_actions %MotorPolicyResult{actions: [], status: :ready}

  describe "highest_confidence_goal" do
    # test_returns_goal_with_highest_confidence
    test "is the goal with the highest confidence" do
      best = goal(:gsg, 0.9, "best")
      second = goal(:gsg, 0.8, "second")

      assert MotorPolicySelectors.highest_confidence_goal([second, best]) == best
    end

    # test_returns_first_goal_when_confidence_tied
    test "is the first of two equally confident goals" do
      first = goal(:gsg, 0.9, "first")
      second = goal(:gsg, 0.9, "second")

      assert MotorPolicySelectors.highest_confidence_goal([first, second]) == first
    end
  end

  describe "SinglePolicySelector" do
    # test_delegates_to_configured_policy
    test "asks its policy, with nil when there is no goal to name" do
      policy = AnsweringPolicy.new([@ready])

      {result, selector} =
        SinglePolicySelector.new(policy: policy)
        |> SinglePolicySelector.call(context(), :observations, :state, :percept, [])

      assert result == @ready
      # Asked once, with no goal to name.
      assert selector.policy.goals == [nil]
    end

    # test_returns_result_from_policy
    test "answers with what its policy answered" do
      {result, _selector} =
        SinglePolicySelector.new(policy: AnsweringPolicy.new([@in_progress]))
        |> SinglePolicySelector.call(context(), :observations, :state, :percept, [])

      assert result == @in_progress
    end

    # test_calls_policy_with_goal_of_highest_confidence
    test "asks its policy about the most confident goal, and records it" do
      best = goal(:sm, 0.9, "best")
      second = goal(:sm, 0.8, "second")
      policy = AnsweringPolicy.new([@ready])

      {_result, selector} =
        SinglePolicySelector.new(policy: policy)
        |> SinglePolicySelector.call(context(), :observations, :state, :percept, [second, best])

      # Monty asserts the policy was called with the goal the helper chose.
      assert selector.policy.goals == [best]
      assert selector.selected_goals == [best]
    end

    # test_reset_calls_reset_on_policy
    test "starts its policy over, and forgets the goals it chose" do
      policy = AnsweringPolicy.new([@ready])

      {_result, selector} =
        SinglePolicySelector.new(policy: policy)
        |> SinglePolicySelector.call(context(), :observations, :state, :percept, [goal(:sm, 0.5)])

      reset = SinglePolicySelector.reset(selector)

      assert reset.policy.goals == []
      assert reset.selected_goals == []
    end

    # test_state_dict_includes_policy_state_dict
    test "carries its policy's record" do
      policy = AnsweringPolicy.new([@ready])

      {_result, selector} =
        SinglePolicySelector.new(policy: policy)
        |> SinglePolicySelector.call(context(), :observations, :state, :percept, [goal(:sm, 0.5)])

      assert SinglePolicySelector.state_dict(selector).policy ==
               AnsweringPolicy.state_dict(selector.policy)
    end
  end

  describe "DistantPolicySelector" do
    # test_returns_default_policy_result_when_no_goals_are_present
    test "asks the default policy when there are no goals" do
      selector = distant(default: AnsweringPolicy.new([@no_actions]))

      {result, selector} =
        DistantPolicySelector.call(selector, context(), :observations, :state, :percept, [])

      assert result == @no_actions
      # The default was asked, with no goal to name.
      assert selector.default.goals == [nil]
    end

    # test_returns_jump_to_goal_result_when_gsg_goal_is_present
    test "jumps when a learning module states a goal" do
      gsg = goal(:gsg, 0.5, "gsg")
      selector = distant(jump_to_goal: AnsweringPolicy.new([@in_progress]))

      {result, selector} =
        DistantPolicySelector.call(selector, context(), :observations, :state, :percept, [
          goal(:sm, 0.5, "sm"),
          gsg,
          goal(:sm, 0.6, "sm")
        ])

      assert result == @in_progress
      assert selector.jump_to_goal.goals == [gsg]
    end

    # test_invokes_jump_to_goal_with_highest_confidence_gsg_goal
    test "jumps toward the most confident learning module goal" do
      best = goal(:gsg, 0.9, "best")
      selector = distant(jump_to_goal: AnsweringPolicy.new([@in_progress]))

      {_result, selector} =
        DistantPolicySelector.call(selector, context(), :observations, :state, :percept, [
          goal(:sm, 0.5, "sm"),
          goal(:gsg, 0.4, "other"),
          best,
          goal(:sm, 0.6, "sm")
        ])

      assert selector.jump_to_goal.goals == [best]
      assert selector.selected_goals == [best]
    end

    # test_returns_look_at_goal_result_when_only_sm_goals_are_present
    # test_invokes_look_at_goal_with_highest_confidence_gsg_goal
    test "looks at the most confident sensor module goal when that is all there is" do
      best = goal(:sm, 0.9, "best")
      selector = distant(look_at_goal: AnsweringPolicy.new([@ready]))

      {result, selector} =
        DistantPolicySelector.call(selector, context(), :observations, :state, :percept, [
          best,
          goal(:sm, 0.8, "second")
        ])

      assert result == @ready
      assert selector.look_at_goal.goals == [best]
      assert selector.selected_goals == [best]
    end

    # test_post_jump_behavior, which Monty parametrizes over eight rows of
    # (undo, a new learning module goal, a new sensor module goal): "undo" is a
    # jump that answers with actions, and it is what makes the verdict final.
    test "a jump in flight is finished before anything else is considered" do
      default_result = %MotorPolicyResult{actions: [:default], status: :ready}
      look_result = %MotorPolicyResult{actions: [:look, :look], status: :ready}
      jump_done = %MotorPolicyResult{actions: [:jump, :jump], status: :ready}

      rows = [
        # {jump's answer now, a learning module goal, a sensor module goal, which policy answers}
        {[@no_actions], false, false, :default},
        {[@no_actions], false, true, :look_at_goal},
        {[@in_progress], true, false, :jump_to_goal},
        {[@in_progress], true, true, :jump_to_goal},
        {[jump_done], false, false, :jump_to_goal},
        {[jump_done], false, true, :jump_to_goal},
        {[jump_done], true, false, :jump_to_goal},
        {[jump_done], true, true, :jump_to_goal}
      ]

      for {answers, learning_module_goal?, sensor_module_goal?, expected} <- rows do
        # A jump that is in flight, as the first call leaves it.
        initial = goal(:gsg, 1.0, "initial")

        selector =
          distant(
            jump_to_goal: AnsweringPolicy.new([@in_progress | answers]),
            look_at_goal: AnsweringPolicy.new([look_result]),
            default: AnsweringPolicy.new([default_result])
          )

        {first, selector} =
          DistantPolicySelector.call(selector, context(), :observations, :state, :percept, [
            initial
          ])

        assert first == @in_progress

        aims = [
          if(learning_module_goal?, do: goal(:gsg, 1.0, "learning module")),
          if(sensor_module_goal?, do: goal(:sm, 1.0, "sensor module"))
        ]

        goals = Enum.reject(aims, &is_nil/1)

        {result, selector} =
          DistantPolicySelector.call(selector, context(), :observations, :state, :percept, goals)

        # What the answering policy answered: the jump's own verdict when the
        # jump is what settled the step.
        expected_result =
          case expected do
            :default -> default_result
            :look_at_goal -> look_result
            :jump_to_goal -> List.last(answers)
          end

        assert result == expected_result

        case expected do
          :default ->
            assert List.last(selector.default.goals) == nil

          :look_at_goal ->
            assert List.last(selector.look_at_goal.goals) == goal(:sm, 1.0, "sensor module")

          :jump_to_goal ->
            # Asked once to start the jump, once now.
            assert length(selector.jump_to_goal.goals) == 2
        end
      end
    end
  end

  defp distant(options) do
    DistantPolicySelector.new(
      jump_to_goal: Keyword.get(options, :jump_to_goal, AnsweringPolicy.new([@no_actions])),
      look_at_goal: Keyword.get(options, :look_at_goal, AnsweringPolicy.new([@no_actions])),
      default: Keyword.get(options, :default, AnsweringPolicy.new([@no_actions]))
    )
  end

  # A context the selectors pass through unread: what a step hands them is the
  # policy's business, and no selector here looks at it.
  defp context, do: :context

  defp goal(sender_type, confidence, sender_id \\ nil) do
    %Goal{sender_type: sender_type, confidence: confidence, sender_id: sender_id}
  end
end
