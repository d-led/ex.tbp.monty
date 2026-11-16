defmodule Monty.Experiment.RecognitionStrategy.MatchCriteriaTest do
  @moduledoc """
  Monty's `tests/unit/experiments/recognition_strategy_test.py::MatchCriteriaTest`,
  case for case: the strategy believes the model's own match criterion, and asks
  it about the modules' terminal states.
  """

  use ExUnit.Case, async: true

  alias Monty.Experiment.MatchCriteria.{AnyLMsMatch, NamedLMsMatch}
  alias Monty.Experiment.RecognitionStrategy
  alias Monty.Experiment.RecognitionStrategy.MatchCriteria
  alias Monty.Experiment.RecognitionStrategy.RecognitionContext
  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  # Monty's `test_done_iff_match_criterion_has_been_met`: done exactly when the
  # criterion says so, and a satisfied criterion times the laggards out with it.
  test "the strategy is done when the model's criterion is satisfied" do
    {:ok, strategy} = MatchCriteria.new()

    assert answer(strategy, %{"lm_0" => :match}, criterion(1)) ==
             %RecognitionResult{is_done: true, time_out_lms: true}

    assert answer(strategy, %{"lm_0" => :time_out, "lm_1" => nil}, criterion(1)) ==
             %RecognitionResult{}
  end

  # The criterion travels with the model, so a strategy built once answers
  # differently per model — which is what makes it the system's usual notion of
  # recognition rather than a step count.
  test "the criterion it applies is the one the model carries" do
    {:ok, strategy} = MatchCriteria.new()
    states = %{"lm_0" => :match, "lm_1" => :no_match}

    assert answer(strategy, states, criterion(1)).is_done
    refute answer(strategy, states, criterion(2)).is_done
    refute answer(strategy, %{"lm_0" => :match}, named(["lm_1"])).is_done
    assert answer(strategy, %{"lm_0" => :match, "lm_1" => :match}, named(["lm_1"])).is_done
  end

  defp criterion(count) do
    {:ok, criterion} = AnyLMsMatch.new(count)
    {AnyLMsMatch, criterion}
  end

  defp named(ids) do
    {:ok, criterion} = NamedLMsMatch.new(ids)
    {NamedLMsMatch, criterion}
  end

  defp answer(strategy, terminal_states, match_criterion) do
    model = %{
      is_done: false,
      is_exploring: false,
      matching_steps: 0,
      conclusions: [],
      terminal_states: terminal_states,
      match_criterion: match_criterion
    }

    RecognitionStrategy.call(strategy, model, RecognitionContext.new(:eval))
  end
end
