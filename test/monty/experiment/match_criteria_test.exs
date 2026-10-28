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
end
