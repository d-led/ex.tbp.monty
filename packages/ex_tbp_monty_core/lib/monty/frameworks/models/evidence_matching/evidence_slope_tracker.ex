defmodule Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker do
  @moduledoc """
  The slope of each hypothesis's evidence over a sliding window.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/evidence_slope_tracker.py`.
  A learning module uses it to drop hypotheses whose evidence is not merely low
  but *falling*: a hypothesis that arrived late has not had time to prove
  itself, so only ones older than `min_age` updates can be removed.

  Slopes are per channel per step, so they stay comparable when the number of
  input channels active at a step changes. That is the whole reason the channel
  counts are buffered alongside the evidence: a step fed by three channels
  accumulates evidence three times as fast, and a slope that ignored it would
  make hypotheses look better simply because more sensors were on them.

  The evidence is a ring of bytes shared by every hypothesis: `evidence` is
  `hypotheses * window_size` f64, `cursor` names the slot the next update
  overwrites — which is also the oldest value in every window — and a window in
  order is `cursor, cursor + 1, … wrap`. Every hypothesis' window slides by one
  slot on the same update, so recording a step writes one value per hypothesis
  and moves the cursor; no window is rebuilt. Sliding ten-slot lists a step was
  the single largest thing a matching step allocated.

  An unfilled slot is a NaN — Monty's `nil`, which a flat window's slope of zero
  must not be mistaken for — so a window cannot be read as floats directly, and
  `calculate_slopes/1` is a kernel over these bytes.
  """

  alias ExTbpMonty.Core.MatcherNif
  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker.HypothesesSelection

  @default_window_size 10
  @default_min_age 5

  # Erlang has no NaN, so this is the one way to write the value both sides
  # agree means "no observation at this slot".
  @not_a_number MatcherNif.not_a_number()

  @enforce_keys [:window_size, :min_age]
  defstruct window_size: @default_window_size,
            min_age: @default_min_age,
            evidence: <<>>,
            ages: [],
            channels: [],
            cursor: 0

  @type value :: float() | nil

  @typedoc """
  `evidence` is `hypotheses * window_size` f64 in ring order, `channels` the
  channel count at each window slot oldest first, and `cursor` the slot the next
  update writes.
  """
  @type t :: %__MODULE__{
          window_size: pos_integer(),
          min_age: non_neg_integer(),
          evidence: binary(),
          ages: [non_neg_integer()],
          channels: [pos_integer()],
          cursor: non_neg_integer()
        }

  @doc """
  A tracker for `window_size` evidence points per hypothesis, allowing removal
  once a hypothesis is `min_age` updates old.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    window_size = Keyword.get(opts, :window_size, @default_window_size)
    min_age = Keyword.get(opts, :min_age, @default_min_age)

    %__MODULE__{
      window_size: window_size,
      min_age: min_age,
      evidence: <<>>,
      ages: [],
      channels: List.duplicate(1, window_size),
      cursor: 0
    }
  end

  @doc "How many hypotheses are tracked."
  @spec total_size(t()) :: non_neg_integer()
  def total_size(%__MODULE__{evidence: evidence, window_size: window_size}),
    do: div(byte_size(evidence), window_size * 8)

  @doc "Which hypotheses are old enough to be considered for removal."
  @spec removable_indices_mask(t()) :: [boolean()]
  def removable_indices_mask(%__MODULE__{ages: ages, min_age: min_age}) do
    Enum.map(ages, &(&1 >= min_age))
  end

  @doc """
  Adds hypotheses, each with an empty window and an age of zero.

  A hypothesis that has never been updated is all padding: it has no slope, and
  `calculate_slopes/1` says so with `nil` rather than with zero.
  """
  @spec add_hyp(t(), non_neg_integer()) :: t()
  def add_hyp(%__MODULE__{} = tracker, count) do
    empty = :binary.copy(@not_a_number, tracker.window_size)

    %{
      tracker
      | evidence: <<tracker.evidence::binary, :binary.copy(empty, count)::binary>>,
        ages: tracker.ages ++ List.duplicate(0, count)
    }
  end

  @doc "The age of every tracked hypothesis, in updates."
  @spec hyp_ages(t()) :: [non_neg_integer()]
  def hyp_ages(%__MODULE__{ages: ages}), do: ages

  @doc """
  Records this step's evidence and moves every window on by one slot.

  `values` is one evidence value per hypothesis — all of them, every step:
  a hypothesis that skipped a step would have a slope over a different number of
  steps from its neighbours, which is how slopes stop being comparable.

  Returns `{:error, :wrong_number_of_values}` rather than raising, because the
  caller is a learning module mid-episode: Monty raises `ValueError`, and the
  reason is the same either way.
  """
  @spec update(t(), [float()] | binary(), keyword()) ::
          {:ok, t()} | {:error, :wrong_number_of_values}
  def update(%__MODULE__{} = tracker, values, opts \\ []) do
    values = values_bytes(values)

    if div(byte_size(values), 8) != total_size(tracker) do
      {:error, :wrong_number_of_values}
    else
      channels = Keyword.get(opts, :num_channels, 1)

      %{
        tracker
        | evidence:
            write_slot(tracker.evidence, values, tracker.cursor * 8, tracker.window_size * 8),
          # Every window shifts by one slot, so the oldest channel count is the
          # one whose evidence the update just overwrote.
          channels: tl(tracker.channels) ++ [channels],
          ages: Enum.map(tracker.ages, &(&1 + 1)),
          cursor: rem(tracker.cursor + 1, tracker.window_size)
      }
      |> then(&{:ok, &1})
    end
  end

  @doc """
  The average per-channel slope of every hypothesis, or `nil` for one whose
  window holds no two consecutive observations.

  Each step's difference is divided by the number of channels that contributed
  at the *later* slot of the pair, then averaged over the window's valid steps.
  """
  @spec calculate_slopes(t()) :: [float() | nil]
  def calculate_slopes(%__MODULE__{} = tracker) do
    channels = tl(tracker.channels)

    if MatcherNif.loaded?() do
      MatcherNif.window_slopes(
        tracker.evidence,
        channels_bytes(channels),
        tracker.window_size,
        tracker.cursor
      )
      |> MatcherNif.decode()
    else
      reference_slopes(tracker.evidence, channels, tracker.window_size, tracker.cursor)
    end
  end

  @doc "Removes the hypotheses at the given indices, keeping the rest in order."
  @spec remove_hyp(t(), [non_neg_integer()]) :: t()
  def remove_hyp(%__MODULE__{} = tracker, indices) do
    remove = MapSet.new(indices)

    tracker
    |> keep_where(fn index, _hypothesis -> not MapSet.member?(remove, index) end)
  end

  @doc "Forgets every hypothesis, keeping the window size and minimum age."
  @spec clear_hyp(t()) :: t()
  def clear_hyp(%__MODULE__{} = tracker) do
    %{tracker | evidence: <<>>, ages: []}
  end

  @doc """
  Which hypotheses to keep, given a slope threshold.

  A hypothesis is kept when its slope is at least the threshold *or* when it is
  too young to remove: the second half is what stops a module from throwing away
  a hypothesis in the same step it was proposed.
  """
  @spec select_hypotheses(t(), float()) :: HypothesesSelection.t()
  def select_hypotheses(%__MODULE__{} = tracker, slope_threshold) do
    tracker
    |> keep_mask(slope_threshold)
    |> HypothesesSelection.new()
  end

  # The mask, as booleans. A kernel answers it in one crossing — one byte a
  # hypothesis, the slopes never leaving the kernel — because the module asks
  # this of every graph on every step and the decode of a slope column, the pair
  # of it with the ages and the walk over the pairs were three passes over the
  # hypothesis set each.
  defp keep_mask(%__MODULE__{} = tracker, slope_threshold) do
    if MatcherNif.loaded?() do
      tracker.evidence
      |> MatcherNif.keep_mask(
        channels_bytes(tl(tracker.channels)),
        tracker.window_size,
        tracker.cursor,
        ages_bytes(tracker.ages),
        tracker.min_age,
        slope_threshold
      )
      |> then(fn mask -> for(<<keep::unsigned-8 <- mask>>, do: keep == 1) end)
    else
      reference_keep_mask(tracker, slope_threshold)
    end
  end

  # The kernel's answer in Elixir, over the same numbers: a hypothesis may be
  # removed only once it is old enough, and a kept one must be rising.
  defp reference_keep_mask(%__MODULE__{} = tracker, slope_threshold) do
    slopes = reference_slopes(tracker.evidence, tl(tracker.channels), tracker.window_size, tracker.cursor)

    [slopes, removable_indices_mask(tracker)]
    |> Enum.zip()
    |> Enum.map(fn {slope, removable?} ->
      not removable? or (not is_nil(slope) and slope >= slope_threshold)
    end)
  end

  defp ages_bytes(ages),
    do: for(age <- ages, into: <<>>, do: <<age::unsigned-32-little>>)

  defp keep_where(%__MODULE__{} = tracker, predicate) do
    row_size = tracker.window_size * 8

    {parts, ages} =
      tracker.ages
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {age, index}, {parts, ages} ->
        row = binary_part(tracker.evidence, index * row_size, row_size)

        if predicate.(index, row),
          do: {[parts, row], [age | ages]},
          else: {parts, ages}
      end)

    %{tracker | evidence: IO.iodata_to_binary(parts), ages: Enum.reverse(ages)}
  end

  # One value per row, all at the same slot: the rows stay hypothesis-major and
  # nothing else in the binary moves. The pieces are gathered and joined once —
  # nesting the concatenation would copy the remaining tail at every row, which
  # is quadratic in the number of hypotheses and was measurably slower than the
  # list shifting this replaced.
  defp write_slot(evidence, values, offset, stride) do
    write_slot(evidence, values, offset, stride, [])
  end

  defp write_slot(rest, <<>>, _offset, _stride, parts), do: IO.iodata_to_binary([parts, rest])

  defp write_slot(evidence, <<value::binary-size(8), values::binary>>, offset, stride, parts) do
    <<skipped::binary-size(^offset), _slot::binary-size(8), rest::binary>> = evidence

    write_slot(rest, values, stride - 8, stride, [parts, skipped, value])
  end

  defp values_bytes(values) when is_binary(values), do: values

  defp values_bytes(values) do
    for value <- values, into: <<>>, do: <<value * 1.0::little-float-64>>
  end

  defp channels_bytes(channels) do
    for channels_here <- channels, into: <<>>, do: <<channels_here * 1.0::little-float-64>>
  end

  # The kernel's arithmetic in Elixir, over the same bytes: each window read in
  # ring order, the steps with two observations added up, the window's mean.
  defp reference_slopes(evidence, channels, window_size, cursor) do
    row_size = window_size * 8
    count = div(byte_size(evidence), row_size)

    for index <- 0..(count - 1)//1 do
      evidence
      |> binary_part(index * row_size, row_size)
      |> window_values(window_size, cursor)
      |> mean_step(channels)
    end
  end

  # The window's slots in the order the hypothesis observed them.
  defp window_values(row, window_size, cursor) do
    for slot <- 0..(window_size - 1)//1 do
      row |> binary_part(rem(cursor + slot, window_size) * 8, 8) |> read_slot()
    end
  end

  defp read_slot(<<bits::unsigned-64-little>>) do
    if not_a_number?(bits) do
      nil
    else
      <<value::float-64-little>> = <<bits::unsigned-64-little>>
      value
    end
  end

  defp not_a_number?(bits) do
    Bitwise.band(bits, 0x7FF0_0000_0000_0000) == 0x7FF0_0000_0000_0000 and
      Bitwise.band(bits, 0x000F_FFFF_FFFF_FFFF) != 0
  end

  # Monty's `np.nanmean(np.diff(window) / channels)`: the mean of the steps that
  # have two observations, and `nil` for a window that has none.
  defp mean_step([_last], _channels), do: nil
  defp mean_step([], _channels), do: nil

  defp mean_step([older | rest], channels), do: mean_step(rest, channels, older, 0.0, 0)

  defp mean_step([], _channels, _older, sum, observed), do: mean(sum, observed)

  defp mean_step([newer | rest], [channels_here | channels], older, sum, observed) do
    {sum, observed} =
      if is_nil(older) or is_nil(newer) do
        {sum, observed}
      else
        {sum + (newer - older) / channels_here, observed + 1}
      end

    mean_step(rest, channels, newer, sum, observed)
  end

  defp mean(_sum, 0), do: nil
  defp mean(sum, count), do: sum / count
end
