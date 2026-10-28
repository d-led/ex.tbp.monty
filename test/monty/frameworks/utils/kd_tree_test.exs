defmodule Monty.Frameworks.Utils.KdTreeTest do
  @moduledoc """
  The nearest-neighbour index agrees with comparing every point.

  A tree exists to be faster than the obvious answer, never to be a different
  one: these tests hold it to the obvious answer, on random points and on the
  shapes that break a naive split — points on a line, points all in one place,
  and queries on top of stored points, where two candidates are equally close.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Frameworks.Utils.KdTree

  defp indexed(points), do: Enum.with_index(points)

  # The answer a tree has to reproduce, including the tie-break: nearest first,
  # then the lower id.
  defp comparing_every_point(points, query, count) do
    points
    |> Enum.map(fn {point, id} -> {squared_distance(query, point), id} end)
    |> Enum.sort()
    |> Enum.take(count)
    |> Enum.map(fn {_distance, id} -> id end)
  end

  defp squared_distance(query, point) do
    query
    |> Enum.zip(point)
    |> Enum.reduce(0.0, fn {a, b}, total -> total + (a - b) * (a - b) end)
  end

  # Quarters rather than arbitrary floats: a grid of points produces plenty of
  # equally distant candidates, which is where a split can go wrong.
  defp coordinate, do: integer(-40..40) |> map(&(&1 / 4))
  defp point, do: list_of(coordinate(), length: 3)

  property "answers what comparing every point answers" do
    check all(
            points <- list_of(point(), min_length: 1, max_length: 40) |> map(&indexed/1),
            query <- point(),
            count <- integer(1..10)
          ) do
      tree = KdTree.build(points)

      assert KdTree.nearest(tree, query, count) == comparing_every_point(points, query, count)
    end
  end

  property "asks for no more points than it holds" do
    check all(
            points <- list_of(point(), min_length: 1, max_length: 20) |> map(&indexed/1),
            query <- point()
          ) do
      tree = KdTree.build(points)

      assert length(KdTree.nearest(tree, query, 50)) == length(points)
    end
  end

  describe "shapes a naive split gets wrong" do
    test "points on a line" do
      points = for x <- 0..20, do: {[x / 10, 0.0, 0.0], x}

      assert KdTree.nearest(KdTree.build(points), [1.02, 0.0, 0.0], 3) == [10, 11, 9]
    end

    test "points that are all in one place, ordered by id" do
      points = for id <- 0..7, do: {[0.5, 0.5, 0.5], id}

      assert KdTree.nearest(KdTree.build(points), [0.5, 0.5, 0.5], 4) == [0, 1, 2, 3]
    end

    test "a query on top of a stored point keeps the closer neighbours" do
      points = [{[0.0, 0.0, 0.0], 0}, {[1.0, 0.0, 0.0], 1}, {[0.1, 0.0, 0.0], 2}]

      assert KdTree.nearest(KdTree.build(points), [0.0, 0.0, 0.0], 2) == [0, 2]
    end

    test "an empty index has nothing near anything" do
      assert KdTree.nearest(KdTree.build([]), [0.0, 0.0, 0.0], 3) == []
    end
  end
end
