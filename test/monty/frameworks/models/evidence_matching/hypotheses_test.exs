defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesTest do
  use ExUnit.Case, async: true

  alias ExTbpMonty.Core.MatcherNif
  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses

  defp hypothesis(evidence, location, possible \\ true) do
    Hypotheses.new(
      evidence: [evidence],
      locations: [location],
      poses: [[[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]],
      possible: [possible]
    )
  end

  defp hypothesis_set(evidence) do
    Enum.reduce(evidence, Hypotheses.empty(), fn value, set ->
      Hypotheses.concatenate([set, hypothesis(value, [0.0, 0.0, 0.0])])
    end)
  end

  defp bytes(values), do: for(value <- values, into: <<>>, do: <<value::little-float-64>>)

  describe "a set of hypotheses" do
    test "is empty, and has a count of zero" do
      empty = Hypotheses.empty()

      assert Hypotheses.count(empty) == 0
      assert Hypotheses.evidence(empty) == []
      assert Hypotheses.locations(empty) == []
      assert Hypotheses.poses(empty) == []
      assert empty.possible == []
    end

    test "knows how many hypotheses it holds" do
      set =
        Hypotheses.concatenate([
          hypothesis(0.5, [0.0, 0.0, 0.0]),
          hypothesis(0.7, [1.0, 0.0, 0.0])
        ])

      assert Hypotheses.count(set) == 2
    end

    # A vote weighs the best hypothesis against the next best, so a step asks
    # this once per object — of the bytes, where the sort it stands for would
    # need every value decoded and a tuple each.
    test "names the runner-up, and nobody when there is no second hypothesis" do
      set = hypothesis_set([1.0, 3.0, 2.0])

      assert Hypotheses.second_argmax_evidence(set) == 2
      assert Hypotheses.evidence_at(set, 2) == 2.0

      assert Hypotheses.second_argmax_evidence(hypothesis_set([2.0])) == nil
      assert Hypotheses.second_argmax_evidence(Hypotheses.empty()) == nil
    end

    # `argsort(evidence)[-2]` on two equal maxima names the lower index: the
    # best of the two sits last in the sorted order, so the one before it is the
    # other tie.
    test "names the other half of two equal maxima as the runner-up" do
      assert Hypotheses.second_argmax_evidence(hypothesis_set([3.0, 3.0, 1.0])) == 0
      assert Hypotheses.second_argmax_evidence(hypothesis_set([1.0, 3.0, 3.0])) == 1
    end

    # The lowest evidence is the threshold that updates the whole field, and it
    # is asked of every graph of every step — so it is answered from the column's
    # bytes, where a value that is not a number has no place in the comparison.
    # `nil` is greater than every number in Elixir's term order, which is what
    # makes "skip it" and `Enum.min/1` the same answer.
    test "the lowest evidence skips the values that are not numbers" do
      not_a_number = MatcherNif.not_a_number()

      assert Hypotheses.min_evidence(hypothesis_set([0.4, 0.2, 0.9])) == 0.2

      with_gaps = %Hypotheses{
        Hypotheses.empty()
        | evidence: not_a_number <> bytes([1.5]) <> not_a_number <> bytes([-0.5])
      }

      assert Hypotheses.min_evidence(with_gaps) == -0.5

      assert Hypotheses.min_evidence(%Hypotheses{
               with_gaps
               | evidence: not_a_number <> not_a_number
             }) == nil

      assert Hypotheses.min_evidence(Hypotheses.empty()) == nil
    end
  end

  describe "concatenating" do
    test "keeps every hypothesis, in the order the sources are given" do
      voted = hypothesis(0.2, [0.0, 1.0, 0.0])
      own = hypothesis(0.9, [1.0, 0.0, 0.0], false)

      set = Hypotheses.concatenate([voted, own])

      assert Hypotheses.evidence(set) == [0.2, 0.9]
      assert Hypotheses.locations(set) == [[0.0, 1.0, 0.0], [1.0, 0.0, 0.0]]
      assert set.possible == [true, false]
      assert length(Hypotheses.poses(set)) == 2
    end

    test "an empty set contributes nothing" do
      only = hypothesis(0.4, [0.0, 0.0, 0.0])

      assert Hypotheses.concatenate([Hypotheses.empty(), only]) == only
      assert Hypotheses.concatenate([only, Hypotheses.empty()]) == only
      assert Hypotheses.concatenate([]) == Hypotheses.empty()
    end

    test "is associative, so a module does not have to care how it was grouped" do
      a = hypothesis(0.1, [0.0, 0.0, 0.0])
      b = hypothesis(0.2, [1.0, 0.0, 0.0])
      c = hypothesis(0.3, [2.0, 0.0, 0.0])

      assert Hypotheses.concatenate([Hypotheses.concatenate([a, b]), c]) ==
               Hypotheses.concatenate([a, Hypotheses.concatenate([b, c])])
    end
  end

  describe "taking a subset" do
    test "keeps the four parallel fields aligned" do
      set =
        Hypotheses.concatenate([
          hypothesis(0.1, [0.0, 0.0, 0.0]),
          hypothesis(0.2, [1.0, 0.0, 0.0], false),
          hypothesis(0.3, [2.0, 0.0, 0.0])
        ])

      subset = Hypotheses.take(set, [2, 0])

      assert Hypotheses.evidence(subset) == [0.3, 0.1]
      assert Hypotheses.locations(subset) == [[2.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
      assert subset.possible == [true, true]
    end

    # The four fields are one walk of the indices now, so what has to hold is that
    # the walk copies each field of the *same* hypothesis — a stride read with the
    # wrong width would pair one hypothesis' place with another's evidence, and a
    # missing reverse would put the rows back to front.
    test "copies each field of the same hypothesis, and nothing at all when asked for nothing" do
      set =
        Hypotheses.concatenate([
          hypothesis(0.1, [0.0, 0.0, 0.0]),
          hypothesis(0.2, [1.0, 0.0, 0.0], false),
          hypothesis(0.3, [2.0, 0.0, 0.0])
        ])

      assert Hypotheses.locations(Hypotheses.take(set, [1])) == [[1.0, 0.0, 0.0]]
      assert Hypotheses.take(set, [1]).possible == [false]

      # The same index twice is two hypotheses: a caller that asked for a row
      # twice gets it twice, in the order it asked.
      twice = Hypotheses.take(set, [2, 2])
      assert Hypotheses.evidence(twice) == [0.3, 0.3]
      assert Hypotheses.locations(twice) == [[2.0, 0.0, 0.0], [2.0, 0.0, 0.0]]

      nothing = Hypotheses.take(set, [])
      assert Hypotheses.evidence(nothing) == []
      assert Hypotheses.locations(nothing) == []
      assert Hypotheses.poses(nothing) == []
      assert nothing.possible == []
    end
  end
end
