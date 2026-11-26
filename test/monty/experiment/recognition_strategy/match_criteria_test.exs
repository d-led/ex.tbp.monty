defmodule Monty.Experiment.RecognitionStrategy.MatchCriteriaTest do
  @moduledoc """
  Monty's `tests/unit/experiments/recognition_strategy_test.py::MatchCriteriaTest`,
  case for case: the strategy asks its own match criterion about the modules'
  terminal states.

  The criterion moved off the model and onto the strategy (Monty's own TODO, in
  `MatchCriteria` before v0.60.0), so the second case pins that the model's
  criterion is no longer the one that answers.
  """

  use ExUnit.Case, async: true

  alias Monty.Experiment.MatchCriteria.{AnyLMsMatch, NamedLMsMatch}
  alias Monty.Experiment.RecognitionStrategy
  alias Monty.Experiment.RecognitionStrategy.MatchCriteria
  alias Monty.Experiment.RecognitionStrategy.RecognitionContext
  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  # Monty's `test_done_iff_match_criterion_has_been_met`: done exactly when the
  # criterion says so, and a satisfied criterion times the laggards out with it.
  test "the strategy is done when its criterion is satisfied" do
    {:ok, strategy} = MatchCriteria.new(match_criterion: criterion(1))

    assert answer(strategy, %{"lm_0" => :match}) ==
             %RecognitionResult{is_done: true, time_out_lms: true}

    assert answer(strategy, %{"lm_0" => :time_out, "lm_1" => nil}) ==
             %RecognitionResult{}
  end

  # A strategy answers the same way whatever the model carries, because the
  # criterion it applies is its own — that is the change this translation pins.
  test "the criterion it applies is the one it was built with, not the model's" do
    {:ok, one} = MatchCriteria.new(match_criterion: criterion(1))
    {:ok, two} = MatchCriteria.new(match_criterion: criterion(2))
    states = %{"lm_0" => :match, "lm_1" => :no_match}

    assert answer(one, states).is_done
    refute answer(two, states).is_done

    {:ok, named} = MatchCriteria.new(match_criterion: names(["lm_1"]))

    refute answer(named, %{"lm_0" => :match}).is_done
    assert answer(named, %{"lm_0" => :match, "lm_1" => :match}).is_done
  end

  defp criterion(count) do
    {:ok, criterion} = AnyLMsMatch.new(count)
    {AnyLMsMatch, criterion}
  end

  defp names(ids) do
    {:ok, criterion} = NamedLMsMatch.new(ids)
    {NamedLMsMatch, criterion}
  end

  # The model always carries a criterion of two modules, so a strategy whose own
  # criterion says one is done anyway: that is what the second case is for.
  defp answer(strategy, terminal_states) do
    model = %{
      is_done: false,
      is_exploring: false,
      matching_steps: 0,
      processed?: true,
      min_train_steps: 0,
      min_eval_steps: 0,
      num_exploratory_steps: 0,
      conclusions: [],
      terminal_states: terminal_states,
      match_criterion: criterion(2)
    }

    RecognitionStrategy.call(strategy, model, RecognitionContext.new(:eval))
  end
end
