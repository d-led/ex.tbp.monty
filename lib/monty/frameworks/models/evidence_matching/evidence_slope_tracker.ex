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

  The evidence is a list of sliding windows, one per hypothesis, oldest first,
  with `nil` where a slot has not been filled yet — Monty's NaN.
  """

  alias Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker.HypothesesSelection

  @default_window_size 10
  @default_min_age 5

  @enforce_keys [:window_size, :min_age]
  defstruct window_size: @default_window_size,
            min_age: @default_min_age,
            evidence: [],
            ages: [],
            channels: []

  @type value :: float() | nil

  @type t :: %__MODULE__{
          window_size: pos_integer(),
          min_age: non_neg_integer(),
          evidence: [[value()]],
          ages: [non_neg_integer()],
          channels: [pos_integer()]
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
      evidence: [],
      ages: [],
      channels: List.duplicate(1, window_size)
    }
  end

  @doc "How many hypotheses are tracked."
  @spec total_size(t()) :: non_neg_integer()
  def total_size(%__MODULE__{evidence: evidence}), do: length(evidence)

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
    empty = List.duplicate(nil, tracker.window_size)

    %{
      tracker
      | evidence: tracker.evidence ++ List.duplicate(empty, count),
        ages: tracker.ages ++ List.duplicate(0, count)
    }
  end

  @doc "The age of every tracked hypothesis, in updates."
  @spec hyp_ages(t()) :: [non_neg_integer()]
  def hyp_ages(%__MODULE__{ages: ages}), do: ages

  @doc """
  Slides every window by one step and records this step's evidence.

  `values` is one evidence value per hypothesis — all of them, every step:
  a hypothesis that skipped a step would have a slope over a different number of
  steps from its neighbours, which is how slopes stop being comparable.

  Returns `{:error, :wrong_number_of_values}` rather than raising, because the
  caller is a learning module mid-episode: Monty raises `ValueError`, and the
  reason is the same either way.
  """
  @spec update(t(), [float()], keyword()) :: {:ok, t()} | {:error, :wrong_number_of_values}
  def update(%__MODULE__{} = tracker, values, opts \\ []) do
    if length(values) != total_size(tracker) do
      {:error, :wrong_number_of_values}
    else
      channels = Keyword.get(opts, :num_channels, 1)

      %{
        tracker
        | evidence: shift_in(tracker.evidence, values),
          channels: shift_in([tracker.channels], [channels]) |> hd(),
          ages: Enum.map(tracker.ages, &(&1 + 1))
      }
      |> then(&{:ok, &1})
    end
  end

  # Slide one window: drop the oldest slot, append the new value.
  defp shift_in(rows, values) do
    Enum.zip_with(rows, values, fn window, value -> tl(window) ++ [value] end)
  end

  @doc """
  The average per-channel slope of every hypothesis, or `nil` for one whose
  window holds no two consecutive observations.

  Each step's difference is divided by the number of channels that contributed
  at the *later* slot of the pair, then averaged over the window's valid steps.
  """
  @spec calculate_slopes(t()) :: [float() | nil]
  def calculate_slopes(%__MODULE__{} = tracker) do
    channel_counts = tl(tracker.channels)

    Enum.map(tracker.evidence, fn window ->
      window
      |> diffs(channel_counts)
      |> valid_slopes()
    end)
  end

  defp diffs([_single], _channels), do: []

  defp diffs([older, newer | rest], [channels | more_channels]) do
    diff =
      if is_nil(older) or is_nil(newer),
        do: nil,
        else: (newer - older) / channels

    [diff | diffs([newer | rest], more_channels)]
  end

  defp diffs([], _channels), do: []

  defp valid_slopes(slopes) do
    valid = Enum.reject(slopes, &is_nil/1)

    case valid do
      [] -> nil
      _some -> Enum.sum(valid) / length(valid)
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
    %{tracker | evidence: [], ages: []}
  end

  @doc """
  Which hypotheses to keep, given a slope threshold.

  A hypothesis is kept when its slope is at least the threshold *or* when it is
  too young to remove: the second half is what stops a module from throwing away
  a hypothesis in the same step it was proposed.
  """
  @spec select_hypotheses(t(), float()) :: HypothesesSelection.t()
  def select_hypotheses(%__MODULE__{} = tracker, slope_threshold) do
    slopes = calculate_slopes(tracker)
    removable = removable_indices_mask(tracker)

    keep =
      [slopes, removable]
      |> Enum.zip()
      |> Enum.map(fn {slope, removable?} ->
        not removable? or (not is_nil(slope) and slope >= slope_threshold)
      end)

    HypothesesSelection.new(keep)
  end

  defp keep_where(%__MODULE__{} = tracker, predicate) do
    {evidence, ages} =
      tracker.evidence
      |> Enum.zip(tracker.ages)
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{window, age}, index}, {evidence, ages} ->
        if predicate.(index, window),
          do: {[window | evidence], [age | ages]},
          else: {evidence, ages}
      end)

    %{tracker | evidence: Enum.reverse(evidence), ages: Enum.reverse(ages)}
  end
end
