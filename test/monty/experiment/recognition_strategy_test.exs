defmodule Monty.Experiment.RecognitionStrategyTest do
  @moduledoc """
  Translations of Monty's `tests/unit/experiments/recognition_strategy_test.py`.

  Monty's cases draw their numbers with Hypothesis; here each is the same
  predicate over a table of values that crosses the boundary it is about — a
  deterministic fixture, which is what the port's generators are.

  Monty's strategies raise `ValueError` from their constructor; a policy here is
  `{module, state}` and its `new/1` answers `{:error, message}` in Monty's own
  words, so a refusal is read off that rather than off an exception.

  Monty holds a strategy inside another by mocking `RecognitionStrategy`'s call;
  `Monty.Experiment.RecognitionStrategy.Answering` is that mock's counterpart.
  """
  use ExUnit.Case, async: true

  alias Monty.Experiment.RecognitionStrategy
  alias Monty.Experiment.RecognitionStrategy.Answering
  alias Monty.Experiment.RecognitionStrategy.CountingCriterion
  alias Monty.Experiment.RecognitionStrategy.MatchCriteria
  alias Monty.Experiment.RecognitionStrategy.MaximumSteps
  alias Monty.Experiment.RecognitionStrategy.MaxTotalSteps
  alias Monty.Experiment.RecognitionStrategy.MinEvalMaxTotalSteps
  alias Monty.Experiment.RecognitionStrategy.MinimumLMs
  alias Monty.Experiment.RecognitionStrategy.StepLimit
  alias Monty.Experiment.RecognitionStrategy.RecognitionContext
  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  describe "MinEvalMaxTotalSteps" do
    # test_raises_value_error_if_min_eval_steps_is_negative
    test "refuses a negative minimum with Monty's words" do
      for min_eval_steps <- [-1, -5, -100] do
        assert MinEvalMaxTotalSteps.new(
                 wrapped: answering(),
                 min_eval_steps: min_eval_steps,
                 max_total_steps: 10
               ) == {:error, "min_eval_steps must be non-negative"}
      end
    end

    # test_raises_value_error_if_max_total_steps_is_not_positive
    test "refuses a ceiling that is not positive with Monty's words" do
      for max_total_steps <- [0, -1, -100] do
        assert MinEvalMaxTotalSteps.new(wrapped: answering(), max_total_steps: max_total_steps) ==
                 {:error, "max_total_steps must be positive"}
      end
    end

    # test_raises_value_error_if_min_eval_steps_is_greater_than_max_total_steps
    test "refuses a minimum above the ceiling with Monty's words" do
      for {max_total_steps, min_eval_steps} <- [{1, 2}, {5, 6}, {100, 101}] do
        assert MinEvalMaxTotalSteps.new(
                 wrapped: answering(),
                 min_eval_steps: min_eval_steps,
                 max_total_steps: max_total_steps
               ) == {:error, "min_eval_steps must be less than or equal to max_total_steps"}
      end
    end

    # test_result_is_not_done_until_min_eval_steps
    test "is not done until the minimum evaluation steps are taken" do
      for {time_out_lms, start_exploring} <- [{false, false}, {true, false}, {false, true}] do
        # What the wrapped strategy answers: done, but held back until the minimum.
        wrapped =
          answering(%RecognitionResult{
            is_done: true,
            time_out_lms: time_out_lms,
            start_exploring: start_exploring
          })

        {:ok, policy} =
          MinEvalMaxTotalSteps.new(wrapped: wrapped, min_eval_steps: 5, max_total_steps: 10)

        for matching_steps <- [0, 4, 5, 6, 10] do
          assert RecognitionStrategy.call(policy, %{is_exploring: false}, %RecognitionContext{
                   matching_steps: matching_steps,
                   mode: :eval
                 }) ==
                   %RecognitionResult{
                     is_done: matching_steps >= 5,
                     time_out_lms: time_out_lms,
                     start_exploring: start_exploring
                   }
        end
      end
    end

    # test_result_is_done_and_time_out_at_max_total_steps
    test "is done, and times the modules out, at the total ceiling" do
      for start_exploring <- [false, true] do
        wrapped =
          answering(%RecognitionResult{
            is_done: false,
            time_out_lms: false,
            start_exploring: start_exploring
          })

        # A minimum at the ceiling, so the held-back branch cannot answer first.
        {:ok, policy} =
          MinEvalMaxTotalSteps.new(wrapped: wrapped, min_eval_steps: 8, max_total_steps: 8)

        for step <- [0, 7, 8, 9] do
          is_done = step >= 8

          assert RecognitionStrategy.call(policy, %{}, %RecognitionContext{step: step}) ==
                   %RecognitionResult{
                     is_done: is_done,
                     time_out_lms: is_done,
                     start_exploring: start_exploring
                   }
        end
      end
    end
  end

  describe "MaxTotalSteps" do
    # test_raises_value_error_if_max_total_steps_is_not_positive
    test "refuses a ceiling that is not positive with Monty's words" do
      for max_total_steps <- [0, -1, -100] do
        assert MaxTotalSteps.new(max_total_steps: max_total_steps) ==
                 {:error, "max_total_steps must be positive"}
      end
    end

    # test_times_out_at_or_after_max_total_steps
    test "is done at the ceiling, and times every module out with it" do
      for max_total_steps <- [1, 2, 5], step <- [0, 1, 2, 4, 5, 6] do
        {:ok, policy} = MaxTotalSteps.new(max_total_steps: max_total_steps)
        is_done = step >= max_total_steps

        # The model is not read at all: Monty's case asserts it is not called.
        assert RecognitionStrategy.call(policy, %{}, %RecognitionContext{step: step}) ==
                 %RecognitionResult{is_done: is_done, time_out_lms: is_done}
      end
    end
  end

  describe "MaximumSteps" do
    # test_raises_value_error_if_max_train_steps_is_not_positive
    test "refuses a training limit that is not positive with Monty's words" do
      for max_train_steps <- [0, -1, -100] do
        assert MaximumSteps.new(max_train_steps: max_train_steps, max_eval_steps: 1) ==
                 {:error, "max_train_steps must be positive"}
      end
    end

    # test_raises_value_error_if_max_eval_steps_is_not_positive
    test "refuses an evaluation limit that is not positive with Monty's words" do
      for max_eval_steps <- [0, -1, -100] do
        assert MaximumSteps.new(max_train_steps: 1, max_eval_steps: max_eval_steps) ==
                 {:error, "max_eval_steps must be positive"}
      end
    end

    # test_times_out_at_or_after_max_steps
    test "is done at or after the limit" do
      for max_steps <- [1, 2, 5], matching_steps <- [0, 1, 2, 4, 5, 6] do
        {:ok, policy} =
          MaximumSteps.new(max_train_steps: max_steps, max_eval_steps: max_steps)

        is_done = matching_steps >= max_steps

        assert RecognitionStrategy.call(policy, %{is_exploring: false}, %RecognitionContext{
                 matching_steps: matching_steps
               }) == %RecognitionResult{is_done: is_done, time_out_lms: is_done}
      end
    end

    # test_no_timeout_if_is_exploring
    test "is never done while the model is exploring" do
      for max_steps <- [1, 2, 5], matching_steps <- [0, 1, 5, 50] do
        {:ok, policy} =
          MaximumSteps.new(max_train_steps: max_steps, max_eval_steps: max_steps)

        assert RecognitionStrategy.call(policy, %{is_exploring: true}, %RecognitionContext{
                 matching_steps: matching_steps
               }).is_done == false
      end
    end

    # test_selects_max_steps_by_mode
    test "counts matching steps against the limit the mode names" do
      {:ok, policy} = MaximumSteps.new(max_train_steps: 3, max_eval_steps: 7)

      for {mode, max_steps} <- [{:train, 3}, {:eval, 7}],
          matching_steps <- [0, 2, 3, 6, 7, 8] do
        is_done = matching_steps >= max_steps

        assert RecognitionStrategy.call(policy, %{is_exploring: false}, %RecognitionContext{
                 mode: mode,
                 matching_steps: matching_steps
               }).is_done == is_done
      end
    end
  end

  describe "StepLimit" do
    # test_raises_value_error_if_min_train_steps_is_negative
    test "refuses a negative minimum training count with Monty's words" do
      for min_train_steps <- [-1, -5, -100] do
        assert StepLimit.new(min_train_steps: min_train_steps) ==
                 {:error, "min_train_steps must be non-negative"}
      end
    end

    # test_raises_value_error_if_num_exploring_steps_is_negative
    test "refuses a negative exploring count with Monty's words" do
      for num_exploring_steps <- [-1, -5, -100] do
        assert StepLimit.new(num_exploring_steps: num_exploring_steps) ==
                 {:error, "num_exploring_steps must be non-negative"}
      end
    end

    # test_raises_value_error_if_max_train_steps_is_not_positive
    test "refuses a training ceiling that is not positive with Monty's words" do
      for max_train_steps <- [0, -1, -100] do
        assert StepLimit.new(max_train_steps: max_train_steps) ==
                 {:error, "max_train_steps must be positive"}
      end
    end

    # test_raises_value_error_if_max_eval_steps_is_not_positive
    test "refuses an evaluation ceiling that is not positive with Monty's words" do
      for max_eval_steps <- [0, -1, -100] do
        assert StepLimit.new(max_eval_steps: max_eval_steps) ==
                 {:error, "max_eval_steps must be positive"}
      end
    end

    # test_matching_times_out_at_or_after_max_steps
    test "times matching out at or after the ceiling, in either mode" do
      for max_steps <- [1, 2, 5], mode <- [:train, :eval], matching_steps <- [0, 1, 2, 5, 6] do
        {:ok, policy} = StepLimit.new(max_train_steps: max_steps, max_eval_steps: max_steps)
        is_done = matching_steps >= max_steps

        assert RecognitionStrategy.call(policy, matching(), %RecognitionContext{
                 matching_steps: matching_steps,
                 mode: mode
               }) == %RecognitionResult{
                 is_done: is_done,
                 time_out_lms: is_done,
                 start_exploring: mode == :train and matching_steps >= 0
               }
      end
    end

    # test_selects_max_steps_by_mode
    test "counts matching steps against the ceiling the mode names" do
      {:ok, policy} = StepLimit.new(max_train_steps: 3, max_eval_steps: 7)

      for {mode, max_steps} <- [{:train, 3}, {:eval, 7}],
          matching_steps <- [0, 2, 3, 6, 7, 8] do
        is_done = matching_steps >= max_steps

        assert RecognitionStrategy.call(policy, matching(), %RecognitionContext{
                 matching_steps: matching_steps,
                 mode: mode
               }).is_done == is_done
      end
    end

    # test_exploring_times_out_at_or_after_num_exploring_steps
    test "times exploring out at or after the exploring count" do
      for num_exploring_steps <- [1, 3], exploring_steps <- [0, 1, 2, 3, 4] do
        {:ok, policy} = StepLimit.new(num_exploring_steps: num_exploring_steps)
        is_done = exploring_steps >= num_exploring_steps

        assert RecognitionStrategy.call(policy, %{is_exploring: true}, %RecognitionContext{
                 exploring_steps: exploring_steps,
                 mode: :train
               }) == %RecognitionResult{is_done: is_done, time_out_lms: is_done}
      end
    end

    # test_switch_to_explore_after_min_train_steps
    test "asks to explore once the minimum training count is reached" do
      {:ok, policy} = StepLimit.new(min_train_steps: 3, max_train_steps: 10)

      for matching_steps <- [3, 5, 9] do
        result =
          RecognitionStrategy.call(policy, matching(), %RecognitionContext{
            matching_steps: matching_steps,
            mode: :train
          })

        assert result.start_exploring
        assert result.is_done == matching_steps >= 10
      end
    end
  end

  describe "MatchCriteria" do
    # test_done_iff_match_criterion_has_been_met
    test "is done when the criterion says so, and asks it exactly once" do
      for matched? <- [true, false] do
        criterion = CountingCriterion.new(self(), matched?)
        {:ok, policy} = MatchCriteria.new(match_criterion: criterion)

        result =
          RecognitionStrategy.call(policy, %{terminal_states: %{}}, %RecognitionContext{})

        assert result.is_done == matched?
        assert result.time_out_lms == matched?
        assert_received :criterion_asked
        refute_received :criterion_asked
      end
    end
  end

  describe "MinimumLMs" do
    # test_raises_value_error_if_min_lms_is_not_positive
    test "refuses a minimum that is not positive with Monty's words" do
      for min_lms <- [0, -1, -100] do
        assert MinimumLMs.new(min_lms: min_lms) == {:error, "min_lms must be positive"}
      end
    end

    # test_done_iff_conclusion_count_reaches_count: Monty draws the conclusions
    # with Hypothesis, up to twenty of them; these are the same counts either
    # side of the minimum.
    test "is done when the conclusions reach the minimum" do
      for min_lms <- [1, 2, 3], concluded <- [0, 1, 2, 3, 4] do
        {:ok, policy} = MinimumLMs.new(min_lms: min_lms)
        conclusions = List.duplicate(:match, concluded) ++ [nil, nil]

        assert RecognitionStrategy.call(
                 policy,
                 %{conclusions: conclusions},
                 %RecognitionContext{}
               ).is_done ==
                 concluded >= min_lms
      end
    end
  end

  # Monty's `MagicMock(RecognitionStrategy, return_value=…)`: a strategy that
  # answers one result, whatever it is asked.
  defp answering(result \\ %RecognitionResult{is_done: true}) do
    {:ok, strategy} = Answering.new(result)
    strategy
  end

  # A model in a matching step: the one field `StepLimit` reads.
  defp matching, do: %{is_exploring: false}
end
