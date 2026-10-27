defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses

  defp hypothesis(evidence, location, possible \\ true) do
    %Hypotheses{
      evidence: [evidence],
      locations: [location],
      poses: [[[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]],
      possible: [possible]
    }
  end

  describe "a set of hypotheses" do
    test "is empty, and has a count of zero" do
      empty = Hypotheses.empty()

      assert Hypotheses.count(empty) == 0
      assert empty.evidence == []
      assert empty.locations == []
      assert empty.poses == []
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
  end

  describe "concatenating" do
    test "keeps every hypothesis, in the order the sources are given" do
      voted = hypothesis(0.2, [0.0, 1.0, 0.0])
      own = hypothesis(0.9, [1.0, 0.0, 0.0], false)

      set = Hypotheses.concatenate([voted, own])

      assert set.evidence == [0.2, 0.9]
      assert set.locations == [[0.0, 1.0, 0.0], [1.0, 0.0, 0.0]]
      assert set.possible == [true, false]
      assert length(set.poses) == 2
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

      assert subset.evidence == [0.3, 0.1]
      assert subset.locations == [[2.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
      assert subset.possible == [true, true]
    end
  end
end
