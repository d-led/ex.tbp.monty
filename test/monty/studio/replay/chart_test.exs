defmodule Monty.Studio.Replay.ChartTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Replay.Chart

  defp points(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, step} -> %{step: step, value: value} end)
  end

  defp series(values, label), do: %{id: label, label: label, points: points(values)}

  describe "a series drawn in a window" do
    test "scales the window across the width and the values across the height" do
      chart = Chart.new(points([0, 1, 2, 3]), window: {0, 3}, playhead: 0)

      assert [%{points: drawn}] = chart.lines
      assert {first_x, first_y} = hd(drawn)
      assert {last_x, last_y} = List.last(drawn)

      assert first_x == 0
      assert last_x == chart.width

      # A rising line is drawn upwards, so its last point is nearer the top.
      assert first_y > last_y
      assert chart.min == 0 and chart.max == 3
    end

    test "draws only the steps the window asks for" do
      chart = Chart.new(points([0, 1, 2, 3, 4]), window: {1, 3}, playhead: 2)

      assert [%{points: drawn}] = chart.lines
      assert Enum.map(drawn, fn {x, _y} -> x end) == [0, chart.width / 2, chart.width]
      assert chart.from == 1 and chart.to == 3
    end

    test "rescales to the window, so a quiet stretch is not a flat line" do
      # Values 10..20 across the whole run are a gentle slope; the window over
      # the last three steps must fill the height like any other series.
      chart = Chart.new(points([10, 11, 12, 19, 20]), window: {3, 4}, playhead: 3)

      assert chart.min == 19 and chart.max == 20

      # The lower value sits at the foot of the chart (minus its inset), the
      # higher one at the top: the window fills the height.
      assert [%{points: drawn}] = chart.lines
      assert Enum.map(drawn, fn {_x, y} -> y end) == [61.0, 3.0]
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

      assert [%{polyline: ""}] = chart.lines
      assert chart.hover == []
    end

    test "a flat series is drawn across the middle" do
      chart = Chart.new(points([5, 5]), window: {0, 1}, playhead: 0)

      assert chart.min == chart.max
      assert [%{points: drawn}] = chart.lines
      assert Enum.map(drawn, fn {_x, y} -> y end) == [32.0, 32.0]
    end

    test "a run of one step is a point in the middle" do
      chart = Chart.new(points([7]), window: {0, 0}, playhead: 0)

      assert [%{points: drawn}] = chart.lines
      assert drawn == [{chart.width / 2, chart.height / 2}]
    end
  end

  describe "several lines on one pair of axes" do
    # Two objects, the first climbing, the second falling: the shape a
    # recognition makes when the wrong guess is ruled out.
    defp two_objects do
      Chart.many([series([0, 4, 8], "mug"), series([8, 4, 0], "bowl")],
        window: {0, 2},
        playhead: 1
      )
    end

    test "every series is a line, numbered so two of them cannot share a colour" do
      assert Enum.map(two_objects().lines, &{&1.label, &1.colour}) == [{"mug", 0}, {"bowl", 1}]
    end

    test "both are scaled to the same range, or each would look like the winner" do
      chart = two_objects()

      assert chart.min == 0
      assert chart.max == 8

      # The first line ends where the second one starts: the top of the chart.
      assert [%{points: mug}, %{points: bowl}] = chart.lines
      assert elem(List.last(mug), 1) == elem(hd(bowl), 1)
    end

    test "the window is the steps every line has, not the first one's" do
      chart =
        Chart.many([
          series([0, 1], "early"),
          %{id: "late", label: "late", points: points([0, 0, 0, 1])}
        ])

      assert chart.from == 0
      assert chart.to == 3
    end

    test "every drawn point knows which line it is on, so a hover can say so" do
      samples = two_objects().hover

      assert Enum.map(samples, & &1.line) == ["mug", "mug", "mug", "bowl", "bowl", "bowl"]

      assert Enum.find(samples, &(&1.line == "bowl" and &1.step == 0)) == %{
               line: "bowl",
               x: 0.0,
               y: 3.0,
               step: 0,
               value: 8
             }
    end
  end
end
