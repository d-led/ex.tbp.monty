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
  alias Monty.Experiment.RecognitionStrategy.MaximumSteps
  alias Monty.Experiment.RecognitionStrategy.MaxTotalSteps
  alias Monty.Experiment.RecognitionStrategy.MinEvalMaxTotalSteps
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

  # Monty's `MagicMock(RecognitionStrategy, return_value=…)`: a strategy that
  # answers one result, whatever it is asked.
  defp answering(result \\ %RecognitionResult{is_done: true}) do
    {:ok, strategy} = Answering.new(result)
    strategy
  end
end
