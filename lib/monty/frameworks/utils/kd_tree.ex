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

    sorted = Enum.sort_by(points, fn {point, id} -> {coordinate(point, axis), id} end)
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
    {ids, _visits} = nearest_with_visits(tree, query, count)
    ids
  end

  @doc """
  The same answer as `nearest/3`, and how many nodes finding it took.

  The count is the point of a tree: a query is supposed to descend to the
  region its answer is in and stop, so the number of nodes it looks at belongs
  to the logarithm of the tree rather than to the number of points. A test can
  hold it to that, which is the only way to notice if pruning stops pruning —
  the answers stay right while the cost goes linear.
  """
  @spec nearest_with_visits(t(), point(), pos_integer()) :: {[id()], non_neg_integer()}
  def nearest_with_visits(:empty, _query, _count), do: {[], 0}

  def nearest_with_visits(tree, query, count) do
    {kept, visits} = query(tree, query, count)
    {kept |> Enum.reverse() |> Enum.map(fn {_distance, id} -> id end), visits}
  end

  @doc """
  The `count` points nearest `query` with their distances, nearest first.

  scipy answers this from the same call as the ids — `return_distance=True` —
  and the distance is what a caller needs when it wants to compare answers
  rather than use them: two objects differ most where one has a part the other
  lacks, which shows up as a node far from everything in the other graph.
  """
  @spec nearest_with_distances(t(), point(), pos_integer()) :: [{float(), id()}]
  def nearest_with_distances(:empty, _query, _count), do: []

  def nearest_with_distances(tree, query, count) do
    {kept, _visits} = query(tree, query, count)

    kept
    |> Enum.reverse()
    |> Enum.map(fn {squared, id} -> {:math.sqrt(squared), id} end)
  end

  defp query(tree, query, count) do
    {{kept, _size}, visits} = search(tree, query, count, {[], 0}, 0)
    {kept, visits}
  end

  # `kept` is worst-first and holds at most `count` answers; `visits` counts the
  # nodes this query has looked at.
  defp search(:empty, _query, _count, kept, visits), do: {kept, visits}

  defp search({point, id, axis, left, right}, query, count, {kept, size}, visits) do
    kept = keep(kept, size, count, {squared_distance(query, point), id})

    difference = coordinate(query, axis) - coordinate(point, axis)
    {near, far} = if difference <= 0, do: {left, right}, else: {right, left}

    {kept, visits} = search(near, query, count, kept, visits + 1)

    # The far side is worth visiting only while it could still hold something
    # closer than the farthest answer kept so far — the head of the list, which
    # is kept worst-first. Comparing against the head itself, rather than its
    # distance, silently compares a number with a tuple and never prunes.
    {[{worst, _worst_id} | _], size} = kept

    if size < count or difference * difference <= worst do
      search(far, query, count, kept, visits)
    else
      {kept, visits}
    end
  end

  # One candidate, worst-first: the farthest kept is dropped when the list is
  # full. A candidate farther than that one costs one comparison.
  defp keep([], _size, _count, candidate), do: {[candidate], 1}

  defp keep(kept, size, count, candidate) do
    [far | rest] = kept

    cond do
      size < count -> {Enum.sort([candidate | kept], :desc), size + 1}
      candidate >= far -> {kept, size}
      true -> {Enum.sort([candidate | rest], :desc), size}
    end
  end

  defp squared_distance([qx, qy, qz], [px, py, pz]) do
    dx = qx - px
    dy = qy - py
    dz = qz - pz

    dx * dx + dy * dy + dz * dz
  end

  defp split_at(list, middle) do
    {before, [at | after_it]} = Enum.split(list, middle)
    {at, before, after_it}
  end

  # The points' bounding box, found in one pass: asking each axis for its own
  # extent walks every point three times, which at sixteen thousand nodes per
  # graph is most of what building a tree costs.
  defp widest_axis(points) do
    {low, high} = bounds(points)

    [low, high]
    |> Enum.zip()
    |> Enum.map(fn {lowest, highest} -> highest - lowest end)
    |> Enum.with_index()
    |> Enum.max_by(fn {spread, _axis} -> spread end)
    |> elem(1)
  end

  defp bounds([{point, _id} | rest]) do
    Enum.reduce(rest, {point, point}, fn {point, _id}, {low, high} ->
      {lowest(low, point), highest(high, point)}
    end)
  end

  defp lowest([lx, ly, lz], [x, y, z]), do: [min(lx, x), min(ly, y), min(lz, z)]
  defp highest([hx, hy, hz], [x, y, z]), do: [max(hx, x), max(hy, y), max(hz, z)]

  defp coordinate([x, _, _], 0), do: x
  defp coordinate([_, y, _], 1), do: y
  defp coordinate([_, _, z], 2), do: z
end
