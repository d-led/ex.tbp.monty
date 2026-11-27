defmodule Monty.Experiment.MatchCriteriaTest do
  use ExUnit.Case, async: true

  alias Monty.Experiment.MatchCriteria.{AnyLMsMatch, NamedLMsMatch}

  describe "enough modules matching" do
    test "one module is enough when that is what was asked for" do
      {:ok, criterion} = AnyLMsMatch.new(1)

      assert AnyLMsMatch.matched?(%{"lm_0" => :match}, criterion)
      refute AnyLMsMatch.matched?(%{"lm_0" => :no_match, "lm_1" => nil}, criterion)
      refute AnyLMsMatch.matched?(%{"lm_0" => :time_out}, criterion)
    end

    test "a quorum counts only the modules that matched" do
      {:ok, criterion} = AnyLMsMatch.new(2)

      refute AnyLMsMatch.matched?(%{"lm_0" => :match, "lm_1" => :no_match}, criterion)
      assert AnyLMsMatch.matched?(%{"lm_0" => :match, "lm_1" => :match}, criterion)
    end

    test "a quorum of nothing would be satisfied before anything was seen" do
      assert {:error, :count_must_be_positive} = AnyLMsMatch.new(0)
    end
  end

  describe "particular modules matching" do
    test "every named module has to agree" do
      {:ok, criterion} = NamedLMsMatch.new(["lm_0", "lm_1"])

      assert NamedLMsMatch.matched?(%{"lm_0" => :match, "lm_1" => :match}, criterion)
      refute NamedLMsMatch.matched?(%{"lm_0" => :match, "lm_1" => :no_match}, criterion)
      refute NamedLMsMatch.matched?(%{"lm_0" => :match}, criterion)
    end

    test "a module nobody named does not count towards it" do
      {:ok, criterion} = NamedLMsMatch.new(["lm_0"])

      assert NamedLMsMatch.matched?(%{"lm_0" => :match, "lm_1" => :no_match}, criterion)
    end

    test "naming nothing would be satisfied before anything was seen" do
      assert {:error, :ids_must_not_be_empty} = NamedLMsMatch.new([])
    end
  end

  # Monty's `tests/unit/experiments/match_criteria_test.py`, case for case. Its
  # `ValueError`s are the port's `{:error, reason}` tuples: a criterion is built
  # where a config is read, and a refusal that names itself there is what the
  # reader acts on.
  describe "Monty's own cases" do
    # test_raises_value_error_if_count_is_not_positive
    test "a count that is not positive is refused, and one is not" do
      assert {:error, :count_must_be_positive} = AnyLMsMatch.new(0)
      assert {:error, :count_must_be_positive} = AnyLMsMatch.new(-1)
      assert {:ok, %AnyLMsMatch{count: 1}} = AnyLMsMatch.new(1)
    end

    # test_returns_true_if_match_terminal_states_count_equals_count
    test "two matches satisfy a count of two" do
      {:ok, criterion} = AnyLMsMatch.new(2)

      assert AnyLMsMatch.matched?(%{"lm1" => :match, "lm2" => :match}, criterion)
    end

    # test_returns_true_if_match_terminal_states_count_is_greater_than_count
    test "three matches satisfy it as well" do
      {:ok, criterion} = AnyLMsMatch.new(2)

      assert AnyLMsMatch.matched?(
               %{"lm1" => :match, "lm2" => :match, "lm3" => :match},
               criterion
             )
    end

    # test_returns_false_if_match_terminal_states_count_is_less_than_count
    test "and one does not" do
      {:ok, criterion} = AnyLMsMatch.new(2)

      refute AnyLMsMatch.matched?(%{"lm1" => :match}, criterion)
    end

    # test_raises_value_error_if_ids_is_empty
    test "no names at all is refused, and one name is not" do
      assert {:error, :ids_must_not_be_empty} = NamedLMsMatch.new([])
      assert {:ok, %NamedLMsMatch{}} = NamedLMsMatch.new(["lm1"])
    end

    # test_returns_true_if_all_ids_are_match
    test "every named module matching is a match" do
      {:ok, criterion} = NamedLMsMatch.new(["lm1", "lm2"])

      assert NamedLMsMatch.matched?(%{"lm1" => :match, "lm2" => :match}, criterion)
    end

    # test_returns_false_if_not_all_ids_are_match
    test "one of them not matching is not" do
      {:ok, criterion} = NamedLMsMatch.new(["lm1", "lm2"])

      refute NamedLMsMatch.matched?(%{"lm1" => :match, "lm2" => :no_match}, criterion)
    end
  end
end
