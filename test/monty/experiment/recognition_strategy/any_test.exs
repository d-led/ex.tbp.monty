defmodule Monty.Experiment.RecognitionStrategy.AnyTest do
  @moduledoc """
  Monty's `tests/unit/experiments/recognition_strategy_test.py::AnyTest`, case for
  case: a combination stops at the first strategy that is done, and answers with
  the union of what it did ask.
  """

  use ExUnit.Case, async: true

  alias Monty.Experiment.RecognitionStrategy
  alias Monty.Experiment.RecognitionStrategy.Any
  alias Monty.Experiment.RecognitionStrategy.RecognitionContext
  alias Monty.Experiment.RecognitionStrategy.RecognitionResult
  alias Monty.Test.RecordingStrategy

  # Monty's `test_raises_value_error_if_strategies_are_empty`: a combination of
  # nothing is a strategy that can never fire.
  test "a combination of nothing is refused" do
    assert Any.new(strategies: []) == {:error, "no strategies to check"}
  end

  # Monty's `test_stops_at_first_strategy_that_is_done`. A strategy after the one
  # that fired must not be asked: it could ask to time modules out, which would
  # then be done on an episode that had already ended.
  test "asking stops at the first strategy that is done" do
    {:ok, any} =
      Any.new(
        strategies: [
          RecordingStrategy.new(:first, %RecognitionResult{}),
          RecordingStrategy.new(:second, %RecognitionResult{is_done: true}),
          RecordingStrategy.new(:third, %RecognitionResult{start_exploring: true})
        ]
      )

    assert ask(any) == %RecognitionResult{is_done: true}
    assert_receive {:asked, :first}
    assert_receive {:asked, :second}
    refute_received {:asked, :third}
  end

  # Monty's `test_recognition_result_aggregation`, both arrangements: one strategy
  # that says nothing, and four where the union of the first three is asked.
  test "the answer is the union of the strategies that were asked" do
    {:ok, one} = Any.new(strategies: [RecordingStrategy.new(:only, %RecognitionResult{})])
    assert ask(one) == %RecognitionResult{}

    {:ok, several} =
      Any.new(
        strategies: [
          RecordingStrategy.new(:exploring, %RecognitionResult{start_exploring: true}),
          RecordingStrategy.new(:done, %RecognitionResult{is_done: true}),
          RecordingStrategy.new(:time_out, %RecognitionResult{time_out_lms: true}),
          RecordingStrategy.new(:never, %RecognitionResult{})
        ]
      )

    # `start_exploring` survives the strategy that ends the episode, and the
    # time-out after it is never asked for.
    assert ask(several) == %RecognitionResult{is_done: true, start_exploring: true}
  end

  defp ask(strategy) do
    model = %{
      is_done: false,
      is_exploring: false,
      matching_steps: 0,
      conclusions: [],
      terminal_states: %{},
      match_criterion: {Monty.Experiment.MatchCriteria.AnyLMsMatch, nil}
    }

    RecognitionStrategy.call(strategy, model, RecognitionContext.new(:eval))
  end
end
