defmodule Monty.Studio.BenchReport do
  @moduledoc """
  What `mix monty.bench` measured, summed up and laid out.

  Two questions, and they are different ones. **How long does a step take** is
  answered by a median, because one unlucky repetition says more about the
  machine than about the code — so the repetition totals are ordered and the
  middle one is reported, never their mean. **How bad does it get** is
  answered by the p95 and the maximum over the individual steps, and by how
  often the vote round hit its deadline, because a mean hides exactly the tail
  that makes a run feel slow.

  The layout is here rather than in the task for one reason: a number wider
  than its column used to run into its neighbour, so a row of real
  measurements read as one absurd one (`716760683306733.8…` was 71.7 s of
  total, 3.3 s per step, and so on, side by side). Column widths are now
  computed from the cells, which is the sort of thing a test can hold.
  """

  @headings ["experiment", "steps", "total µs", "µs/step", "p50", "p95", "max", "deadlines"]

  @typedoc """
  One repetition: the per-step durations it saw, and the summary it produced.
  """
  @type sample :: %{durations: [non_neg_integer()], summary: Monty.Studio.Summary.t()}

  @type measurement :: %{
          experiment: String.t(),
          steps: non_neg_integer(),
          total_us: number(),
          mean_us: float(),
          p50_us: number(),
          p95_us: number(),
          max_us: number(),
          deadline_hits: non_neg_integer(),
          runnable?: boolean()
        }

  @doc """
  Sums up `samples` of the same experiment.

  `steps` is what was asked for, so a run that ended early is still declared
  as the size it was meant to be.
  """
  @spec summarise(String.t(), [sample()], non_neg_integer()) :: measurement()
  def summarise(experiment, samples, steps) do
    durations = samples |> Enum.map(& &1.durations) |> List.flatten() |> Enum.sort()

    %{
      experiment: experiment,
      steps: steps,
      total_us: samples |> Enum.map(& &1.summary.duration_us) |> Enum.sort() |> median(),
      mean_us: durations |> Enum.sum() |> Kernel./(max(length(durations), 1)),
      p50_us: percentile(durations, 0.50),
      p95_us: percentile(durations, 0.95),
      max_us: List.last(durations) || 0,
      deadline_hits: samples |> Enum.map(& &1.summary.deadline_hits) |> Enum.max(fn -> 0 end),
      runnable?: true
    }
  end

  @doc """
  The measurement of an experiment that would not start, or could not be
  opened. Its zeroes are honest: nothing was measured.
  """
  @spec not_runnable(String.t(), non_neg_integer()) :: measurement()
  def not_runnable(experiment, steps) do
    %{
      experiment: experiment,
      steps: steps,
      total_us: 0,
      mean_us: 0.0,
      p50_us: 0,
      p95_us: 0,
      max_us: 0,
      deadline_hits: 0,
      runnable?: false
    }
  end

  @doc """
  The measurements as lines of a table: a heading, then one row each.

  Every line is the same width, which is what keeps a wide number under its
  own heading.
  """
  @spec table([measurement()]) :: [String.t()]
  def table(results) do
    rows = Enum.map(results, &row/1)
    widths = widths([@headings | rows])

    [line(@headings, widths) | Enum.map(rows, &line(&1, widths))]
  end

  defp row(measurement) do
    [
      measurement.experiment,
      Integer.to_string(measurement.steps),
      Integer.to_string(measurement.total_us),
      :erlang.float_to_binary(measurement.mean_us, decimals: 1),
      Integer.to_string(measurement.p50_us),
      Integer.to_string(measurement.p95_us),
      Integer.to_string(measurement.max_us),
      Integer.to_string(measurement.deadline_hits)
    ]
  end

  # Each column is as wide as its widest cell — the heading included, so a
  # short value never sits under a truncated heading.
  defp widths(rows) do
    rows
    |> Enum.zip()
    |> Enum.map(fn column ->
      column |> Tuple.to_list() |> Enum.map(&String.length/1) |> Enum.max()
    end)
  end

  defp line(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.with_index()
    |> Enum.map_join("  ", fn {{cell, width}, index} -> pad(cell, width, index) end)
  end

  # The experiment name grows to the right; every number grows to the left, so
  # its last digit stays where the heading's last character is.
  defp pad(cell, width, 0), do: String.pad_trailing(cell, width)
  defp pad(cell, width, _column), do: String.pad_leading(cell, width)

  defp median([]), do: 0
  defp median(sorted), do: Enum.at(sorted, div(length(sorted), 2))

  defp percentile([], _fraction), do: 0

  defp percentile(sorted, fraction) do
    index = round(fraction * (length(sorted) - 1))
    Enum.at(sorted, index)
  end
end
