defmodule Monty.Frameworks.Models.GraphMatching.MontyForGraphMatchingTest do
  @moduledoc """
  Monty's `MontyForGraphMatching._combine_votes`, for the votes the graph-matching
  family actually sends: sets of ruled-out objects.

  The evidence family's votes — hypotheses with their poses — are a different
  calculation over a different shape, and they are tested where that calculation
  lives (`...EvidenceMatching.Model.MontyForEvidenceGraphMatchingTest`).
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.GraphMatching.MontyForGraphMatching

  # A ring: each module hears from the two beside it, which is Monty's
  # `lm_to_lm_vote_matrix` in its simplest form.
  defp ring(count) do
    Map.new(0..(count - 1), fn index ->
      {index, [rem(index + 1, count), rem(index + 2, count)]}
    end)
  end

  describe "what a module hears" do
    test "is the union of what its sources ruled out" do
      votes = %{0 => MapSet.new(["mug"]), 1 => MapSet.new(["mug", "bowl"]), 2 => MapSet.new([])}

      heard = MontyForGraphMatching.combine_votes(votes, ring(3))

      # Each module hears from the two beside it: 0 from 1 and 2, 1 from 2 and 0,
      # 2 from 0 and 1.
      assert Map.fetch!(heard, 0) |> Enum.sort() == ["bowl", "mug"]
      assert heard[1] == ["mug"]
      assert Map.fetch!(heard, 2) |> Enum.sort() == ["bowl", "mug"]
    end

    # A module that ruled every object in has ruled nothing out, and one that did
    # not vote at all is silence. Neither may stop the round: the run that found
    # this was a five-module ring whose first vote round answered with an empty
    # set, and the evidence family's combiner had no clause for it.
    test "ignores a silent module, and answers an empty list for an empty union" do
      votes = %{0 => MapSet.new([]), 1 => nil, 2 => MapSet.new(["mug"])}

      heard = MontyForGraphMatching.combine_votes(votes, ring(3))

      assert heard == %{0 => ["mug"], 1 => ["mug"], 2 => []}
    end
  end
end
