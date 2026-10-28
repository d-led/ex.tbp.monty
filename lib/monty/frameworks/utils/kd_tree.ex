defmodule Monty.Frameworks.Utils.KdTree do
  @moduledoc """
  A k-nearest-neighbour index over points.

  Monty asks scipy for this — `KDTree(graph.pos)` — and then queries it once per
  hypothesis to find the stored nodes an unobserved pose would have been seen
  from. Comparing against every node instead is the same answer at a cost that
  grows with the product of hypotheses and nodes: a pretrained object of two
  thousand nodes matched by two thousand hypotheses is four million distance
  calculations per graph per step, and that is where most of the port's time
  went.

  So this is the same structure scipy builds: a binary tree that splits the
  points along whichever axis they are most spread over, at their median, so a
  query descends to the region its answer is in and stops looking at regions
  that cannot beat what it already has. It is our own code rather than a port —
  scipy's tree is not part of Monty — and is documented as such.

  ## Determinism

  Answers are ordered nearest first, and a tie in distance goes to the lower id,
  which is what makes two runs of the same episode choose the same nodes. Points
  are taken as `{point, id}` pairs so the caller decides what an id is.
  """

  @type point :: [number()]
  @type id :: non_neg_integer()
  @type t :: :empty | {point(), id(), axis :: 0 | 1 | 2, t(), t()}

  @doc """
  Indexes `points`, each a `{point, id}` pair.
  """
  @spec build([{point(), id()}]) :: t()
  def build([]), do: :empty

  def build(points) do
    axis = widest_axis(points)

    sorted = Enum.sort_by(points, fn {point, id} -> {Enum.at(point, axis), id} end)
    middle = div(length(sorted), 2)
    {{point, id}, left, right} = split_at(sorted, middle)

    {point, id, axis, build(left), build(right)}
  end

  @doc """
  The ids of the `count` points nearest `query`, nearest first.

  Fewer than `count` when the tree holds fewer points.
  """
  @spec nearest(t(), point(), pos_integer()) :: [id()]
  def nearest(:empty, _query, _count), do: []

  def nearest(tree, query, count) do
    tree
    |> search(query, count, [])
    |> Enum.map(fn {_distance, id} -> id end)
  end

  # Closest first, and by id where two points are equally close: the answer a
  # caller can reproduce.
  defp search(:empty, _query, _count, best), do: best

  defp search({point, id, axis, left, right}, query, count, best) do
    best = insert(best, {squared_distance(query, point), id}, count)

    difference = Enum.at(query, axis) - Enum.at(point, axis)
    {near, far} = if difference <= 0, do: {left, right}, else: {right, left}

    best = search(near, query, count, best)

    # The far side is worth visiting only while it could still hold something
    # closer than the worst point kept so far.
    if length(best) < count or difference * difference <= worst(best) do
      search(far, query, count, best)
    else
      best
    end
  end

  defp insert(best, candidate, count) do
    best
    |> insert_sorted(candidate)
    |> Enum.take(count)
  end

  defp insert_sorted([], candidate), do: [candidate]

  defp insert_sorted([head | _] = sorted, candidate) when candidate <= head,
    do: [candidate | sorted]

  defp insert_sorted([head | rest], candidate),
    do: [head | insert_sorted(rest, candidate)]

  defp worst(best), do: best |> List.last() |> elem(0)

  defp squared_distance(query, point) do
    query
    |> Enum.zip(point)
    |> Enum.reduce(0.0, fn {a, b}, total -> total + (a - b) * (a - b) end)
  end

  defp split_at(list, middle) do
    {before, [at | after_it]} = Enum.split(list, middle)
    {at, before, after_it}
  end

  defp widest_axis(points) do
    0..2
    |> Enum.max_by(&spread(points, &1))
  end

  defp spread(points, axis) do
    values = Enum.map(points, fn {point, _id} -> Enum.at(point, axis) end)
    Enum.max(values) - Enum.min(values)
  end
end
