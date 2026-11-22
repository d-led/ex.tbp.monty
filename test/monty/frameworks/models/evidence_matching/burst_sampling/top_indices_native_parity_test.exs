defmodule Monty.Frameworks.Models.EvidenceMatching.BurstSampling.TopIndicesNativeParityTest do
  @moduledoc """
  The kernel names the same nodes as the reference, in the same order.

  `MatcherNif.top_indices/2` partitions the column at the boundary of the last
  `count` and sorts only that tail; the reference sorts every answer and takes the
  end. Both are the order `Enum.sort_by(&{evidence, index})` defines, so the two
  have to answer the same list — not near enough: the answer is a set of
  positions in a graph, and one that differs is a different burst.
  """

  use ExUnit.Case, async: true

  alias ExTbpMonty.Core.MatcherNif
  alias Monty.Frameworks.Models.EvidenceMatching.BurstSampling.BurstSamplingHypothesesUpdater

  # A column as the graph holds it: f64 little-endian, one answer a node. `:nan`
  # is a node whose features said nothing, which the order puts above every
  # number.
  defp column(values) do
    for value <- values, into: <<>> do
      case value do
        :nan -> <<0x7FF8000000000000::unsigned-64-little>>
        number -> <<number::float-64-little>>
      end
    end
  end

  defp kernel(values, count) do
    values
    |> column()
    |> MatcherNif.top_indices(count)
    |> then(fn chosen -> for <<index::unsigned-32-little <- chosen>>, do: index end)
  end

  defp reference(values, count),
    do: BurstSamplingHypothesesUpdater.reference_top_indices(column(values), count)

  # A column with the shapes a graph has: repeats, a node with no answer, both
  # signs of zero, and more nodes than the burst keeps.
  defp awkward do
    [0.5, -0.0, 0.0, 1.25, 0.5, :nan, -2.0, 0.5, 3.0, -0.0, 1.25, :nan] ++
      for(index <- 1..300, do: rem(index * 7919, 41) / 8.0 - 2.5)
  end

  test "the kernel and the reference choose the same nodes" do
    cases = [
      {[], 0},
      {[], 4},
      {[1.0], 1},
      {[1.0], 9},
      {[1.0, 2.0, 3.0], 2},
      {[3.0, 1.0, 2.0], 3},
      {[1.0, 1.0, 1.0, 1.0, 1.0], 2},
      {[1.0, :nan, 2.0], 2},
      {[-0.0, 0.0], 1},
      {awkward(), 1},
      {awkward(), 7},
      {awkward(), 100},
      {awkward(), 312}
    ]

    for {values, count} <- cases do
      assert kernel(values, count) == reference(values, count),
             "a column of #{length(values)} nodes, keeping #{count}"
    end
  end

  test "and the order they share is the one a burst depends on" do
    # The highest evidence is last, and equal evidence is settled by position:
    # a burst that samples the same nodes twice would otherwise depend on which
    # of two equal answers the sort happened to see first.
    assert kernel([1.0, 3.0, 2.0], 2) == [2, 1]
    assert kernel([1.0, 1.0, 1.0, 1.0, 1.0], 2) == [3, 4]

    # A node with no answer is not a low answer: it sorts above the numbers.
    assert kernel([1.0, :nan, 2.0], 2) == [2, 1]
  end
end
