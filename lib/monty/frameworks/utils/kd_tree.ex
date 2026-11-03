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

  # `:empty`, or the point stored, its id, the axis it was split on, and the two
  # subtrees — the lower-coordinate one on the left.
  @type tree :: :empty | {number(), number(), number(), id(), 0 | 1 | 2, tree(), tree()}

  # Either engine's index: the native one, when this VM built one, or the tree.
  @type t :: {:nif, reference()} | tree()

  # What a native answer uses where a query found fewer neighbours than asked.
  @no_neighbour 4_294_967_295

  @doc """
  Indexes `points`, each a `{point, id}` pair.

  The native index when this machine has one, the tree below otherwise. Both
  answer the same question; `build_elixir/1` is the one that says which.
  """
  @spec build([{point(), id()}]) :: t()
  def build(points) do
    if ExTbpMonty.KdTreeNif.loaded?() and consecutive?(points) do
      {:nif, ExTbpMonty.KdTreeNif.build(positions(points))}
    else
      build_elixir(points)
    end
  end

  @doc """
  The reference index: our own tree, in Elixir.

  This is what the tests describe — including how many nodes a query looks at —
  and what runs wherever the native index is not built. A caller asking for it
  by name wants that answer, not the fastest one.
  """
  @spec build_elixir([{point(), id()}]) :: tree()
  def build_elixir([]), do: :empty

  def build_elixir(points) do
    axis = widest_axis(points)

    sorted = Enum.sort_by(points, fn {point, id} -> {coordinate(point, axis), id} end)
    middle = div(length(sorted), 2)
    {{[x, y, z], id}, left, right} = split_at(sorted, middle)

    {x * 1.0, y * 1.0, z * 1.0, id, axis, build_elixir(left), build_elixir(right)}
  end

  @doc """
  The ids of the `count` points nearest `query`, nearest first.

  Fewer than `count` when the tree holds fewer points.
  """
  @spec nearest(t(), point(), pos_integer()) :: [id()]
  def nearest(:empty, _query, _count), do: []

  def nearest({:nif, _index} = tree, query, count) do
    [ids] = nearest_many(tree, [query], count)
    ids
  end

  def nearest(tree, query, count) do
    {ids, _visits} = nearest_with_visits(tree, query, count)
    ids
  end

  @doc """
  The ids of the `count` points nearest each of `queries`, one list per query.

  One call for a step's worth of questions, in the order they were asked, and
  each answer is exactly what `nearest/3` would have said: a caller never has to
  interleave the index with its own loop. On the native index this is genuinely
  one call — twenty thousand queries cross the boundary once, not twenty
  thousand times.
  """
  @spec nearest_many(t(), [point()], pos_integer()) :: [[id()]]
  def nearest_many(:empty, _queries, _count), do: []

  def nearest_many({:nif, _index}, _queries, 0), do: []

  def nearest_many({:nif, index}, queries, count) do
    index
    |> ExTbpMonty.KdTreeNif.nearest_many(points_bytes(queries), count)
    |> ids_in()
    |> Enum.chunk_every(count)
    |> Enum.map(fn ids -> Enum.reject(ids, &(&1 == @no_neighbour)) end)
  end

  def nearest_many(tree, queries, count), do: Enum.map(queries, &nearest(tree, &1, count))

  @doc """
  The same answers as `nearest_many/3`, left as the bytes the index wrote.

  Nothing is decoded, rejected or grouped: the answer is `{ids, count}` —
  `queries * count` little-endian u32 ids, row after row, with
  `4_294_967_295` where a query found fewer than `count` — because the caller is
  a native kernel that reads them there. Decoding twenty thousand ids into lists
  of lists was a fifth of what the answers cost, and the kernel can skip the
  marker itself.

  `nil` for a tree that is not the native index: the Elixir tree has no such
  bytes, and a caller that needs them keeps the decoded path.
  """
  @spec nearest_many_ids(t(), [point()], pos_integer()) :: {binary(), pos_integer()} | nil
  def nearest_many_ids({:nif, index}, queries, count) do
    {ExTbpMonty.KdTreeNif.nearest_many(index, points_bytes(queries), count), count}
  end

  def nearest_many_ids(_tree, _queries, _count), do: nil

  @doc """
  Points as the bytes an index or a kernel reads: three little-endian f64 each.

  Public so that a caller which asks two native things about the same points
  encodes them once, and so that both see exactly the same numbers.
  """
  @spec points_bytes([point()]) :: binary()
  def points_bytes(points) do
    for point <- points, into: <<>>, do: point_bytes(point)
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

  def nearest_with_distances({:nif, index}, query, count) do
    {ids, distances} =
      ExTbpMonty.KdTreeNif.nearest_many_with_distances(index, points_bytes([query]), count)

    ids
    |> ids_in()
    |> Enum.zip(distances_in(distances))
    |> Enum.reject(fn {id, _distance} -> id == @no_neighbour end)
    |> Enum.map(fn {id, distance} -> {distance, id} end)
  end

  def nearest_with_distances(tree, query, count) do
    {kept, _visits} = query(tree, query, count)

    kept
    |> Enum.reverse()
    |> Enum.map(fn {squared, id} -> {:math.sqrt(squared), id} end)
  end

  # The descent threads its answers as `{kept, size}`; a query wants only the
  # answers and the number of nodes that found them.
  defp query(tree, query, count) do
    {{kept, _size}, visits} = search(tree, triple(query), count, {[], 0}, 0)
    {kept, visits}
  end

  # `kept` is worst-first and holds at most `count` answers, with its own size
  # beside it; `visits` counts the nodes this query has looked at.
  defp search(:empty, _query, _count, kept, visits), do: {kept, visits}

  defp search({x, y, z, id, axis, left, right}, {qx, qy, qz}, count, {kept, size}, visits) do
    dx = qx - x
    dy = qy - y
    dz = qz - z

    kept = keep(kept, size, count, dx * dx + dy * dy + dz * dz, id)

    # The one coordinate this node splits on, and nothing else. Inlined rather
    # than a helper: a visit is the unit cost of the whole module, and a call
    # plus the tuple it returns to say "which side" is a quarter of it.
    difference =
      if axis == 0, do: dx, else: if(axis == 1, do: dy, else: dz)

    {near, far} = if difference <= 0, do: {left, right}, else: {right, left}
    {kept, visits} = search(near, {qx, qy, qz}, count, kept, visits + 1)

    # The far side is worth visiting only while it could still hold something
    # closer than the farthest answer kept so far — the head of the list, which
    # is kept worst-first, and its *distance* rather than the entry: a number
    # compared with a `{distance, id}` tuple is always less in Erlang's term
    # order, so comparing entries never prunes.
    {[{worst, _worst_id} | _], size} = kept

    if size < count or difference * difference <= worst do
      search(far, {qx, qy, qz}, count, kept, visits)
    else
      {kept, visits}
    end
  end

  # One candidate, worst-first: the farthest kept is dropped when the list is
  # full. A candidate farther than that one costs one comparison; anything else
  # is walked into a list that is already in order, which is cheaper than
  # sorting four entries for every node visited. The distance and the id arrive
  # apart so that a visit allocates nothing for a candidate it discards.
  defp keep([], _size, _count, distance, id), do: {[{distance, id}], 1}

  defp keep([{_worst, _worst_id} = head | rest], size, count, distance, id) do
    candidate = {distance, id}

    cond do
      # Not full yet: the candidate goes wherever it belongs, including at the
      # head — the head has to stay the farthest answer, because pruning reads it.
      size < count -> {insert([head | rest], candidate), size + 1}
      candidate >= head -> {[head | rest], size}
      true -> {insert(rest, candidate), size}
    end
  end

  # Into a list that is already worst-first, at the first entry it beats. A tie
  # in distance sorts by id descending, so that reversing the list puts the lower
  # id first — the rule `nearest/3` promises.
  defp insert([], candidate), do: [candidate]

  defp insert([head | rest] = list, candidate),
    do: if(head >= candidate, do: [head | insert(rest, candidate)], else: [candidate | list])

  defp split_at(list, middle) do
    {before, [at | after_it]} = Enum.split(list, middle)
    {at, before, after_it}
  end

  # The points' bounding box, found in one pass: asking each axis for its own
  # extent walks every point three times, which at sixteen thousand nodes per
  # graph is most of what building a tree costs.
  defp widest_axis(points) do
    {low, high} = bounds(points)

    [
      elem(high, 0) - elem(low, 0),
      elem(high, 1) - elem(low, 1),
      elem(high, 2) - elem(low, 2)
    ]
    |> Enum.with_index()
    |> Enum.max_by(fn {spread, _axis} -> spread end)
    |> elem(1)
  end

  defp bounds([{point, _id} | rest]) do
    {x, y, z} = triple(point)

    Enum.reduce(rest, {{x, y, z}, {x, y, z}}, fn {point, _id}, {low, high} ->
      {x, y, z} = triple(point)
      {lowest(low, x, y, z), highest(high, x, y, z)}
    end)
  end

  defp lowest({lx, ly, lz}, x, y, z), do: {min(lx, x), min(ly, y), min(lz, z)}
  defp highest({hx, hy, hz}, x, y, z), do: {max(hx, x), max(hy, y), max(hz, z)}

  defp coordinate(point, 0), do: point |> triple() |> elem(0)
  defp coordinate(point, 1), do: point |> triple() |> elem(1)
  defp coordinate(point, 2), do: point |> triple() |> elem(2)

  defp triple([x, y, z]), do: {x, y, z}
  defp triple({x, y, z}), do: {x, y, z}

  # -- the native boundary --------------------------------------------------
  #
  # Points cross as bytes, not as lists: twenty thousand queries worth of
  # little triples is a megabyte either way, and building them costs less than
  # asking the runtime to encode them.

  defp positions(points) do
    for {point, _id} <- points, into: <<>>, do: point_bytes(point)
  end

  defp point_bytes(point) do
    {x, y, z} = triple(point)
    <<x * 1.0::little-float-64, y * 1.0::little-float-64, z * 1.0::little-float-64>>
  end

  defp ids_in(bytes), do: for(<<id::little-32 <- bytes>>, do: id)
  defp distances_in(bytes), do: for(<<value::little-float-64 <- bytes>>, do: value)

  # The native index takes a point's id to be its position, so it can only answer
  # for points numbered that way — which is how every caller in this port
  # numbers them. Any other numbering keeps the Elixir tree.
  defp consecutive?(points) do
    points
    |> Enum.with_index()
    |> Enum.all?(fn {{_point, id}, index} -> id == index end)
  end
end
