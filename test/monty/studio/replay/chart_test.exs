defmodule Monty.Studio.Replay.ChartTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Replay.Chart

  defp points(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, step} -> %{step: step, value: value} end)
  end

  describe "a series drawn in a window" do
    test "scales the window across the width and the values across the height" do
      chart = Chart.new(points([0, 1, 2, 3]), window: {0, 3}, playhead: 0)

      assert {first_x, first_y} = hd(chart.points)
      assert {last_x, last_y} = List.last(chart.points)

      assert first_x == 0
      assert last_x == chart.width

      # A rising line is drawn upwards, so its last point is nearer the top.
      assert first_y > last_y
      assert chart.min == 0 and chart.max == 3
    end

    test "draws only the steps the window asks for" do
      chart = Chart.new(points([0, 1, 2, 3, 4]), window: {1, 3}, playhead: 2)

      assert Enum.map(chart.points, fn {x, _y} -> x end) == [0, chart.width / 2, chart.width]
      assert chart.from == 1 and chart.to == 3
    end

    test "rescales to the window, so a quiet stretch is not a flat line" do
      # Values 10..20 across the whole run are a gentle slope; the window over
      # the last three steps must fill the height like any other series.
      chart = Chart.new(points([10, 11, 12, 19, 20]), window: {3, 4}, playhead: 3)

      assert chart.min == 19 and chart.max == 20

      # The lower value sits at the foot of the chart (minus its inset), the
      # higher one at the top: the window fills the height.
      assert chart.points |> Enum.map(fn {_x, y} -> y end) == [61.0, 3.0]
    end

    test "puts the playhead where the step is" do
      chart = Chart.new(points([0, 1, 2, 3]), window: {0, 3}, playhead: 2)

      assert_in_delta chart.playhead, chart.width * 2 / 3, 0.0001
    end

    test "has no playhead when the page is not showing a step" do
      assert Chart.new(points([0, 1]), window: {0, 1}).playhead == nil
    end

    test "an empty window is a chart, not a crash" do
      chart = Chart.new([], window: {})

      assert chart.polyline == ""
      assert chart.points == []
    end

    test "a flat series is drawn across the middle" do
      chart = Chart.new(points([5, 5]), window: {0, 1}, playhead: 0)

      assert chart.min == chart.max
      assert chart.points |> Enum.map(fn {_x, y} -> y end) == [32.0, 32.0]
    end

    test "a run of one step is a point in the middle" do
      chart = Chart.new(points([7]), window: {0, 0}, playhead: 0)

      assert chart.points == [{chart.width / 2, chart.height / 2}]
    end
  end
end
