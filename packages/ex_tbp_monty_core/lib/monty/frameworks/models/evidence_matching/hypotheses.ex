defmodule Monty.Frameworks.Models.EvidenceMatching.Hypotheses do
  @moduledoc """
  A set of hypotheses: their evidence, the location each implies, the pose each
  implies, and whether each can still be possible.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/hypotheses.py`. The
  four fields are parallel — an index is one hypothesis in all of them — which
  is why Monty keeps them as separate arrays rather than a list of records: a
  learning module selects, masks and weights whole columns of them with one
  operation.

  In Elixir `possible` is a list, one flag per hypothesis, and `evidence`,
  `locations` and `poses` are the same rows as **bytes**: eight little-endian
  f64 of evidence, then three of location and nine of rotation each, in the
  order the hypothesis index names them. That is the form a step needs them in —
  it displaces every hypothesis, blends what each earned into a column, then
  asks the k-d index about every location and a kernel for the evidence at each
  — so holding them this way stops a step from rebuilding a list, and eight or
  three or nine boxed floats a hypothesis, once per pass. `evidence/1`,
  `evidence_at/2`, `locations/1`, `location/2`, `poses/1` and `pose/2` read them
  back, one hypothesis at a time where that is all a caller wants.

  `empty/0` is the identity for `concatenate/1`, which is what lets a learning
  module build a step's hypotheses from however many sources voted.
  """

  alias ExTbpMonty.Core.MatcherNif

  @enforce_keys [:evidence, :locations, :poses, :possible]
  defstruct [:evidence, :locations, :poses, :possible]

  @location_width 3
  @pose_width 9

  @type location :: [float()]
  @type pose :: [[float()]]

  @typedoc """
  `evidence` is `hypotheses` f64, `locations` `hypotheses * 3` f64 and `poses`
  `hypotheses * 9` f64, all in the hypothesis's own order; `possible` has one
  entry each.
  """
  @type t :: %__MODULE__{
          evidence: binary(),
          locations: binary(),
          poses: binary(),
          possible: [boolean()]
        }

  @doc "The hypotheses of nothing: the identity for `concatenate/1`."
  @spec empty() :: t()
  def empty, do: %__MODULE__{evidence: <<>>, locations: <<>>, poses: <<>>, possible: []}

  @doc """
  One set of hypotheses from the rows of each, in order.

  The caller speaks in the shapes it has — evidence as a number, a location as
  `[x, y, z]`, a pose as three rows — and this is the one place those become the
  bytes a step reads.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    %__MODULE__{
      evidence: values_bytes(Keyword.fetch!(fields, :evidence)),
      locations: bytes(Keyword.fetch!(fields, :locations), &location_bytes/1),
      poses: bytes(Keyword.fetch!(fields, :poses), &pose_bytes/1),
      possible: Keyword.fetch!(fields, :possible)
    }
  end

  @doc """
  One hypothesis per node per pose — the shape a burst samples in.

  `locations` and `evidence` name the chosen nodes once; `poses` holds one
  matrix per hypothesis in that order, pose-major, which is what aligning each
  sensed direction against the nodes produces. The node block is encoded once
  and copied, where `new/1` would encode the same few hundred nodes once per
  sensed direction: a burst samples eight poses at each of a few hundred nodes,
  ten graphs at a time, so that is tens of thousands of rows of the same values
  every step.
  """
  @spec per_pose(keyword()) :: t()
  def per_pose(fields) do
    locations = fields |> Keyword.fetch!(:locations) |> bytes(&location_bytes/1)
    evidence = fields |> Keyword.fetch!(:evidence) |> values_bytes()
    poses = fields |> Keyword.fetch!(:poses) |> bytes(&pose_bytes/1)

    # The poses name every hypothesis; the nodes only one round of them, so the
    # node block is copied once per round. `max` keeps the round count defined
    # for the burst that chose no node at all — no node is no hypothesis, and
    # copying an empty block however many times leaves it empty.
    hypotheses = div(byte_size(poses), @pose_width * 8)
    nodes = max(div(byte_size(locations), @location_width * 8), 1)
    rounds = div(hypotheses, nodes)

    %__MODULE__{
      locations: :binary.copy(locations, rounds),
      evidence: :binary.copy(evidence, rounds),
      poses: poses,
      possible: List.duplicate(false, hypotheses)
    }
  end

  @doc """
  One set of hypotheses from several, in order.

  Monty concatenates along the hypothesis axis, so votes from two learning
  modules produce their votes first and the receiving module's hypotheses
  second, in the order the caller passes them.
  """
  @spec concatenate([t()]) :: t()
  def concatenate(hyps) do
    %__MODULE__{
      evidence: for(hypotheses <- hyps, into: <<>>, do: hypotheses.evidence),
      locations: for(hypotheses <- hyps, into: <<>>, do: hypotheses.locations),
      poses: for(hypotheses <- hyps, into: <<>>, do: hypotheses.poses),
      possible: Enum.flat_map(hyps, & &1.possible)
    }
  end

  @doc "How many hypotheses the set holds."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{evidence: evidence}), do: div(byte_size(evidence), 8)

  @doc "Every hypothesis' evidence, as the numbers they are."
  @spec evidence(t()) :: [float() | nil]
  def evidence(%__MODULE__{evidence: bytes}), do: MatcherNif.decode(bytes)

  @doc "One hypothesis' evidence."
  @spec evidence_at(t(), non_neg_integer()) :: float() | nil
  def evidence_at(%__MODULE__{evidence: bytes}, index) do
    bytes
    |> binary_part(index * 8, 8)
    |> MatcherNif.decode()
    |> hd()
  end

  @doc """
  The evidence column as a step holds it: one f64 per hypothesis.

  What a kernel reads, where `evidence/1` is what a reporter or an argmax wants.
  """
  @spec evidence_bytes(t()) :: binary()
  def evidence_bytes(%__MODULE__{evidence: bytes}), do: bytes

  @doc "The same hypotheses with a new evidence column, given as numbers."
  @spec put_evidence(t(), [float()]) :: t()
  def put_evidence(%__MODULE__{} = hypotheses, values),
    do: %__MODULE__{hypotheses | evidence: values_bytes(values)}

  @doc """
  The index of the most likely hypothesis — the first of several equal maxima.

  Asked far more often than any other question of the column, so it is asked of
  the bytes: a kernel when they are loaded, and the same walk in Elixir otherwise.
  """
  @spec argmax_evidence(t()) :: non_neg_integer()
  def argmax_evidence(%__MODULE__{} = hypotheses) do
    if MatcherNif.loaded?() do
      MatcherNif.argmax_index(evidence_bytes(hypotheses))
    else
      hypotheses |> evidence() |> argmax()
    end
  end

  @doc "The highest evidence any hypothesis holds."
  @spec max_evidence(t()) :: float() | nil
  def max_evidence(%__MODULE__{evidence: <<>>}), do: nil

  def max_evidence(%__MODULE__{} = hypotheses),
    do: evidence_at(hypotheses, argmax_evidence(hypotheses))

  @doc """
  The index of the runner-up hypothesis, or `nil` when there is no second one.

  Monty reads it as `argsort(evidence)[-2]` to weigh a vote between the two best
  hypotheses, and a step asks once per object. Asked of the bytes: the sort it
  stands for needs every value decoded and a tuple for each.
  """
  @spec second_argmax_evidence(t()) :: non_neg_integer() | nil
  def second_argmax_evidence(%__MODULE__{evidence: bytes}) when byte_size(bytes) < 16, do: nil

  def second_argmax_evidence(%__MODULE__{} = hypotheses) do
    if MatcherNif.loaded?() do
      MatcherNif.second_argmax_index(evidence_bytes(hypotheses))
    else
      hypotheses |> evidence() |> second_argmax()
    end
  end

  # The reference: sort by `{value, index}` and take the one before the last, as
  # `Enum.sort_by/2` orders a `nil` above every number.
  defp second_argmax(values) do
    values
    |> Enum.with_index()
    |> Enum.sort_by(fn {value, index} -> {value, index} end)
    |> Enum.at(-2)
    |> elem(1)
  end

  @doc """
  The indices of the hypotheses within `percentage` per cent of the best one.

  Monty's `get_possible_hypothesis_ids`: `np.where(evidence > max - max / 100 *
  x_percent_threshold)`, once the best clears `floor`. A learning module asks
  once per object per step, so it is answered from the bytes.

  Two edges are numpy's rather than Elixir's, and they are the reason the answer
  is stated here: a column with a NaN in it has no best at all — `np.max`
  propagates the NaN, every comparison against one is false — so nothing is
  possible; and the band is strict, so a hypothesis exactly at the threshold is
  out.
  """
  @spec indices_within(t(), float(), number()) :: [non_neg_integer()]
  def indices_within(%__MODULE__{evidence: <<>>}, _percentage, _floor), do: []

  def indices_within(%__MODULE__{} = hypotheses, percentage, floor) do
    if MatcherNif.loaded?() do
      hypotheses
      |> evidence_bytes()
      |> MatcherNif.indices_within(percentage, floor)
      |> index_list()
    else
      hypotheses
      |> evidence()
      |> within_fraction(percentage, floor)
    end
  end

  # The reference, in numpy's terms: no best when any value is a NaN, and a
  # strict band under the best.
  defp within_fraction(values, percentage, floor) do
    if Enum.any?(values, &is_nil/1) do
      []
    else
      best = Enum.max(values)

      if best > floor do
        threshold = best - best / 100 * percentage

        for {value, index} <- Enum.with_index(values), value > threshold, do: index
      else
        []
      end
    end
  end

  @doc "Indices as Elixir values, read out of the u32 bytes a kernel answers with."
  @spec index_list(binary()) :: [non_neg_integer()]
  def index_list(bytes), do: for(<<index::32-little <- bytes>>, do: index)

  @doc """
  The lowest evidence any hypothesis holds — the threshold that updates them all.

  `evidence_threshold_config: "all"` asks this once per graph per step, and the
  answer is one number: asked of the bytes, a minimum of six thousand of them no
  longer costs six thousand decoded floats.
  """
  @spec min_evidence(t()) :: float() | nil
  def min_evidence(%__MODULE__{evidence: <<>>}), do: nil

  def min_evidence(%__MODULE__{} = hypotheses) do
    if MatcherNif.loaded?() do
      MatcherNif.min_value(evidence_bytes(hypotheses))
    else
      Enum.min(evidence(hypotheses), fn -> nil end)
    end
  end

  # numpy's `argmax`: the first index holding the highest value.
  defp argmax([]), do: 0

  defp argmax([first | rest]) do
    rest
    |> Enum.with_index(1)
    |> Enum.reduce({first, 0}, fn {value, index}, {best, best_index} ->
      if value > best, do: {value, index}, else: {best, best_index}
    end)
    |> elem(1)
  end

  @doc "The same hypotheses with a new evidence column a kernel has written."
  @spec put_evidence_bytes(t(), binary()) :: t()
  def put_evidence_bytes(%__MODULE__{} = hypotheses, bytes),
    do: %__MODULE__{hypotheses | evidence: bytes}

  @doc "Every hypothesis' location, as the three values each one is."
  @spec locations(t()) :: [location()]
  def locations(%__MODULE__{locations: bytes}),
    do: rows(bytes, @location_width, &decode_location/1)

  @doc "One hypothesis' location."
  @spec location(t(), non_neg_integer()) :: location()
  def location(%__MODULE__{locations: bytes}, index) do
    bytes
    |> binary_part(index * @location_width * 8, @location_width * 8)
    |> decode_location()
  end

  @doc "Every hypothesis' rotation, as the matrix each one is."
  @spec poses(t()) :: [pose()]
  def poses(%__MODULE__{poses: bytes}), do: rows(bytes, @pose_width, &decode_pose/1)

  @doc "One hypothesis' rotation."
  @spec pose(t(), non_neg_integer()) :: pose()
  def pose(%__MODULE__{poses: bytes}, index) do
    bytes
    |> binary_part(index * @pose_width * 8, @pose_width * 8)
    |> decode_pose()
  end

  @doc """
  The hypotheses at the given indices, in the order asked for.

  Used by a learning module to keep the hypotheses it still considers possible
  without rebuilding four columns by hand. A kept row is copied out of the row
  it was already in, so this does not go back through the values themselves.
  """
  @spec take(t(), [non_neg_integer()]) :: t()
  def take(%__MODULE__{} = hypotheses, indices) do
    # One pass to a tuple, then a constant-time lookup per index: reading them
    # out of lists by index walks the list every time, which over a hypothesis
    # space of thousands turns a selection into tens of millions of steps.
    possible = List.to_tuple(hypotheses.possible)

    {evidence, locations, poses} = gather_all(hypotheses, indices)

    %__MODULE__{
      evidence: evidence,
      possible: Enum.map(indices, &elem(possible, &1)),
      locations: locations,
      poses: poses
    }
  end

  # Four passes — three gathers and the map over `possible` — was tried as one pass
  # that collects the columns as iolists and concatenates each once, and it measured
  # 173.35 µs against 171.22 µs per selection of 2 000 rows out of 4 000 (1.01x, on
  # the data a step has): a selection is dominated by copying the rows themselves —
  # 144 kB of poses, once per object per step — not by walking the index list four
  # times. The version that reads better stayed.
  defp gather_all(hypotheses, indices) do
    if MatcherNif.loaded?() do
      # The copy is the cost, so it happens in the kernel at the width each column
      # needs; the indices are encoded once for the three columns.
      encoded = index_bytes(indices)

      {MatcherNif.gather_rows(hypotheses.evidence, 1, encoded),
       MatcherNif.gather_rows(hypotheses.locations, @location_width, encoded),
       MatcherNif.gather_rows(hypotheses.poses, @pose_width, encoded)}
    else
      {gather(hypotheses.evidence, indices, 1),
       gather(hypotheses.locations, indices, @location_width),
       gather(hypotheses.poses, indices, @pose_width)}
    end
  end

  @doc "Indices as the u32 bytes a kernel reads them from."
  @spec index_bytes([non_neg_integer()]) :: binary()
  def index_bytes(indices), do: for(index <- indices, into: <<>>, do: <<index::32-little>>)

  @doc """
  The rows of the hypotheses at `indices`, as the bytes a kernel reads.

  What a step needs when it asks about a subset — the hypotheses worth testing
  this observation — without decoding them into values first.
  """
  @spec rows_at(t(), [non_neg_integer()]) :: {binary(), binary()}
  def rows_at(%__MODULE__{} = hypotheses, indices) do
    if MatcherNif.loaded?() do
      encoded = index_bytes(indices)

      {MatcherNif.gather_rows(hypotheses.locations, @location_width, encoded),
       MatcherNif.gather_rows(hypotheses.poses, @pose_width, encoded)}
    else
      {gather(hypotheses.locations, indices, @location_width),
       gather(hypotheses.poses, indices, @pose_width)}
    end
  end

  @doc "The bytes of one location, as a step holds it."
  @spec location_bytes(location()) :: binary()
  def location_bytes([x, y, z]) do
    <<x * 1.0::little-float-64, y * 1.0::little-float-64, z * 1.0::little-float-64>>
  end

  @doc "The locations in `bytes`, as values — the reference's way of reading them."
  @spec locations_of(binary()) :: [location()]
  def locations_of(bytes), do: rows(bytes, @location_width, &decode_location/1)

  @doc "The rotations in `bytes`, as values — the reference's way of reading them."
  @spec poses_of(binary()) :: [pose()]
  def poses_of(bytes), do: rows(bytes, @pose_width, &decode_pose/1)

  @doc "The bytes of one rotation, row by row, as a step holds it."
  @spec pose_bytes(pose()) :: binary()
  def pose_bytes([[p, q, r], [s, t, u], [v, w, x]]) do
    <<p * 1.0::little-float-64, q * 1.0::little-float-64, r * 1.0::little-float-64,
      s * 1.0::little-float-64, t * 1.0::little-float-64, u * 1.0::little-float-64,
      v * 1.0::little-float-64, w * 1.0::little-float-64, x * 1.0::little-float-64>>
  end

  defp bytes(rows, encode), do: for(row <- rows, into: <<>>, do: encode.(row))

  defp values_bytes(values) do
    for value <- values, into: <<>>, do: <<value * 1.0::little-float-64>>
  end

  defp rows(bytes, width, decode), do: rows(bytes, width * 8, decode, [])

  defp rows(<<>>, _size, _decode, acc), do: Enum.reverse(acc)

  defp rows(bytes, size, decode, acc) do
    <<row::binary-size(^size), rest::binary>> = bytes
    rows(rest, size, decode, [decode.(row) | acc])
  end

  defp gather(_bytes, [], _width), do: <<>>

  defp gather(bytes, indices, width) do
    size = width * 8

    for index <- indices, into: <<>>, do: binary_part(bytes, index * size, size)
  end

  defp decode_location(<<x::little-float-64, y::little-float-64, z::little-float-64>>),
    do: [x, y, z]

  defp decode_pose(
         <<p::little-float-64, q::little-float-64, r::little-float-64, s::little-float-64,
           t::little-float-64, u::little-float-64, v::little-float-64, w::little-float-64,
           x::little-float-64>>
       ),
       do: [[p, q, r], [s, t, u], [v, w, x]]
end
