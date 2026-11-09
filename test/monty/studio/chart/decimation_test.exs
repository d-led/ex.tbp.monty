defmodule Monty.Studio.Chart.DecimationTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Chart

  # A plot of one thousand steps across its width: the chart's own key set, and
  # nothing else, because the decimation only ever asks for the frame.
  @chart %{x_min: 0, x_max: 19_999, width: 320}

  defp run(steps, value), do: Enum.map(steps, &{0, &1, value.(&1)})

  describe "a run longer than the plot is wide" do
    setup do
      points = run(0..19_999, fn step -> :math.sin(step / 250) * 100 end)

      %{points: points, drawn: Chart.decimate(points, @chart)}
    end

    test "is drawn with a fraction of the samples it was given", %{points: points, drawn: drawn} do
      assert length(drawn) < length(points) / 10
    end

    test "is drawn with samples it was actually given", %{points: points, drawn: drawn} do
      assert Enum.all?(drawn, &(&1 in points))
    end

    test "is drawn in step order, because a polyline is a sequence", %{drawn: drawn} do
      steps = Enum.map(drawn, &elem(&1, 1))

      assert steps == Enum.sort(steps)
    end
  end

  # The reason the extremes are kept rather than an average: an average would
  # flatten the two moments the chart exists to show.
  describe "the extremes of the run" do
    test "survive, at the step they happened on" do
      points =
        run(0..19_999, fn
          5_000 -> 1000.0
          15_000 -> -1000.0
          _step -> 0.0
        end)

      drawn = Chart.decimate(points, @chart)

      assert {0, 5_000, 1000.0} in drawn
      assert {0, 15_000, -1000.0} in drawn
    end
  end

  describe "a run of one or two samples" do
    test "comes back untouched, sample for sample" do
      points = run(0..1, fn step -> step * 1.0 end)

      assert Chart.decimate(points, @chart) == points
    end

    test "and so does an empty one" do
      assert Chart.decimate([], @chart) == []
    end
  end

  # Three samples inside one column is not a short run, it is a crowded column:
  # the middle one is invisible at this scale, and the two the line is drawn
  # through — the column's first and last — are also its lowest and highest here.
  describe "samples that share a column" do
    test "are reduced to the ones that can be seen" do
      points = run(0..2, fn step -> step * 1.0 end)

      assert Chart.decimate(points, @chart) == [{0, 0, 0.0}, {0, 2, 2.0}]
    end
  end
end
