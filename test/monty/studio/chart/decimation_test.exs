defmodule Monty.Studio.Chart.DecimationTest do
  @moduledoc """
  A picture has a few hundred columns; a run has thousands of steps. What a line
  is drawn through is therefore a choice, and this is the choice: a column keeps
  its first, its lowest, its highest and its last sample, and every other sample
  in it was invisible when it was sent.

  These are the cases of that cut, asked of `Chart.new/2` — which is where the
  cut now happens, inside the pass that reads the run, rather than as a second
  step over samples built for the whole run. The second step cost a second of
  drawing for a run of thirty thousand steps, and a page following a run asks
  for a drawing four times a second.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Chart

  # A plot of twenty thousand steps across its width: about seventy steps to a
  # column, which is what makes the cut visible at all.
  @long_run 0..19_999

  defp steps(step_range, evidence) do
    Enum.map(step_range, &{0, &1, belief(evidence.(&1))})
  end

  defp belief(evidence) do
    %{
      possible_matches: ["mug"],
      mlh: nil,
      graphs: %{
        "mug" => %{
          hypotheses: 10,
          max_evidence: evidence,
          within_x_percent: 1,
          top_evidence: [evidence]
        }
      },
      x_percent_threshold: 20,
      terminal_state: nil,
      detected_object: nil
    }
  end

  defp drawn(step_range, evidence, options \\ []) do
    chart = Chart.new(steps(step_range, evidence), options)
    [%{evidence: drawn}] = chart.series

    drawn
  end

  describe "a run longer than the plot is wide" do
    test "is drawn with a fraction of the samples it was given" do
      pointed = drawn(@long_run, &(:math.sin(&1 / 250) * 100))

      assert length(pointed) < Enum.count(@long_run) / 10
    end

    test "is drawn with samples it was actually given, and nothing invented" do
      pointed = drawn(@long_run, &(:math.sin(&1 / 250) * 100))

      assert Enum.all?(pointed, fn {step, evidence} -> evidence == :math.sin(step / 250) * 100 end)
    end

    test "is drawn in step order, because a polyline is a sequence" do
      steps_drawn = drawn(@long_run, &(&1 * 1.0)) |> Enum.map(&elem(&1, 0))

      assert steps_drawn == Enum.sort(steps_drawn)
    end

    # What a column is allowed to keep: the samples its line can be seen
    # through, four of them, and the columns are the plot's own width.
    test "is drawn with at most four samples a column" do
      chart = Chart.new(steps(@long_run, &(&1 * 1.0)), width: 320)
      [mug] = chart.series
      columns = chart.width - chart.margin_left - chart.margin_right

      assert length(mug.evidence) <= 4 * columns
    end
  end

  # The reason the extremes are kept rather than an average: an average would
  # flatten the two moments the chart exists to show.
  describe "the extremes of the run" do
    test "survive, at the step they happened on" do
      pointed =
        drawn(
          @long_run,
          fn
            5_000 -> 1000.0
            15_000 -> -1000.0
            _step -> 0.0
          end
        )

      assert {5_000, 1000.0} in pointed
      assert {15_000, -1000.0} in pointed
    end
  end

  describe "a run of one or two samples" do
    test "comes back untouched, sample for sample" do
      assert drawn(0..1, &(&1 * 1.0)) == [{0, 0.0}, {1, 1.0}]
    end

    test "and a run of one sample is that sample" do
      assert drawn(0..0, &(&1 * 1.0)) == [{0, 0.0}]
    end

    test "and so does an empty one, which has no line at all" do
      assert Chart.new([]).series == []
    end
  end
end
