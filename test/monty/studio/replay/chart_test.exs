defmodule Monty.Studio.Replay.ChartTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Replay.Chart

  defp points(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {value, step} -> %{step: step, value: value} end)
  end

  defp series(values, label), do: %{id: label, label: label, points: points(values)}

  # The y of one "x,y" point of a polyline.
  defp ordinate(point) do
    {value, _rest} = point |> String.split(",") |> List.last() |> Float.parse()
    value
  end

  # The one line a chart draws, as the points it is written with.
  defp drawn_points(chart) do
    [%{polylines: [line]}] = chart.lines

    line
    |> String.split(" ")
    |> Enum.map(fn point ->
      {x, y} = point |> String.split(",") |> Enum.map(&float_of/1) |> List.to_tuple()
      {x, y}
    end)
  end

  defp float_of(number) do
    {value, _rest} = Float.parse(number)
    value
  end

  describe "the line the values are measured from" do
    test "is drawn where the axis admits zero" do
      chart = Chart.many([series([0.0, 2.0, -1.0], "mug")])

      # Between the top and the bottom of the plot, and inside the inset: zero
      # of a -1..2 range is a third of the way up.
      assert chart.zero > 0 and chart.zero < chart.height
      assert_in_delta chart.zero, chart.height - 2, chart.height * 0.5
    end

    test "is kept when the values themselves never come near it" do
      # Evidence is a sum that starts at zero, and Monty's dashboard draws the
      # axis from there: an axis that began at the lowest line would turn "40"
      # into forty above wherever the weakest line happened to be.
      chart = Chart.many([series([30.0, 34.0, 38.0], "mug")])

      assert chart.min == 0
      assert Enum.any?(chart.ticks, &(&1.label == "0"))
      assert chart.zero > 0 and chart.zero < chart.height
    end
  end

  describe "the episodes the chart shades" do
    # Evidence restarts at zero at every boundary, so a run's lines climb and drop
    # in a rhythm. One band per episode, each in a colour of its own — the pyview
    # dashboard's bands — is what makes that rhythm countable.
    test "is one band per episode, and neighbouring bands never share a colour" do
      chart =
        Chart.new([
          %{step: 0, value: 1.0, episode: 0},
          %{step: 1, value: 2.0, episode: 0},
          %{step: 2, value: 1.0, episode: 1},
          %{step: 3, value: 2.0, episode: 1}
        ])

      assert [first, second] = chart.bands
      assert {first.episode, second.episode} == {0, 1}
      assert first.colour != second.colour
      assert first.width > 0 and second.width > 0
    end

    test "tiles the axis, so no step falls between two bands" do
      chart =
        Chart.new([
          %{step: 0, value: 1.0, episode: 0},
          %{step: 1, value: 2.0, episode: 0},
          %{step: 2, value: 1.0, episode: 1},
          %{step: 3, value: 2.0, episode: 1}
        ])

      assert [first, second] = chart.bands

      # The first episode ends where the second begins: a gap would be a
      # boundary the chart drew but the run did not have.
      assert_in_delta first.x + first.width, second.x, 0.001
      assert_in_delta second.x + second.width, chart.width, 0.001
    end

    test "an episode of a single step at the edge has no width, so it is left out" do
      chart =
        Chart.new([
          %{step: 0, value: 1.0, episode: 0},
          %{step: 1, value: 2.0, episode: 0},
          %{step: 2, value: 1.0, episode: 1}
        ])

      assert [band] = chart.bands
      assert band.episode == 0
    end

    test "a chart whose series carries no episodes is not shaded at all" do
      assert Chart.new(points([1, 2, 3])).bands == []
    end
  end

  describe "the numbers on the value axis" do
    test "land on a step a reader already has, not on the range cut into parts" do
      # Twelve units of evidence is labelled every five, not every 3.75: the
      # labels are one, two or five times a power of ten, chosen so the axis
      # carries about four of them.
      chart = Chart.many([series([0.0, 12.0], "mug")])

      assert Enum.map(chart.ticks, & &1.label) == ["0", "5", "10"]
    end

    test "name zero whenever the axis spans it" do
      # Evidence is measured from zero, so an axis that reaches under it says
      # where zero is. Cutting the range into quarters left 0 between -1.4 and
      # 3.7, so the line that every episode starts on had no name.
      chart = Chart.many([series([-6.4, 8.7], "mug")])

      labels = Enum.map(chart.ticks, & &1.label)

      assert labels == ["-5", "0", "5"]
      assert Enum.any?(chart.ticks, &(&1.value == 0.0))
    end

    test "carry as many decimals as the step needs, so no two labels read alike" do
      chart = Chart.many([series([0.0, 0.9], "mug")])

      assert Enum.map(chart.ticks, & &1.label) == ["0.0", "0.5"]
    end

    test "widen with the range instead of crowding it" do
      chart = Chart.many([series([0.0, 250.0], "mug")])

      assert Enum.map(chart.ticks, & &1.label) == ["0", "100", "200"]
    end
  end

  describe "a series drawn in a window" do
    test "scales the window across the width and the values across the height" do
      chart = Chart.new(points([0, 1, 2, 3]), window: {0, 3}, playhead: 0)

      assert [%{points: drawn}] = chart.lines
      assert {first_x, first_y} = hd(drawn)
      assert {last_x, last_y} = List.last(drawn)

      # The plot is the whole width: the value labels live beside it, not in it.
      assert first_x == 0
      assert last_x == chart.width

      # A rising line is drawn upwards, so its last point is nearer the top.
      assert first_y > last_y
      assert chart.min == 0 and chart.max == 3
    end

    test "scales the value axis to the window, not to the tallest step in the run" do
      # A run with one runaway episode in it: an axis taken from the whole run
      # drew the other seventy-five episodes as a line at the bottom of a box
      # whose top belonged to an episode nobody was looking at. Zooming in has
      # to rescale, or there is no detail to read at any zoom.
      series = [
        %{id: "mug", label: "mug", unit: "", points: points([5.0, 10.0, 700.0])}
      ]

      whole = Chart.many(series)
      near = Chart.many(series, window: {0, 1})

      assert whole.max == 700
      assert near.max == 10
      assert near.min == 0
    end

    test "draws only the steps the window asks for" do
      chart = Chart.new(points([0, 1, 2, 3, 4]), window: {1, 3}, playhead: 2)

      assert [%{points: drawn}] = chart.lines
      assert Enum.map(drawn, fn {x, _y} -> x end) == [0, chart.width / 2, chart.width]
      assert chart.from == 1 and chart.to == 3
    end

    test "zooming narrows the axis, and leaves the values where they were" do
      # Values 10..20 across the whole run are a gentle slope. Zoomed to the last
      # two steps, the line is still the same line on the same axis: a scale per
      # window redrew every line against a new one, so walking along a run
      # rewrote the picture instead of moving along it.
      whole = Chart.new(points([10, 11, 12, 19, 20]), window: {0, 4}, playhead: 0)
      zoomed = Chart.new(points([10, 11, 12, 19, 20]), window: {3, 4}, playhead: 3)

      assert zoomed.min == whole.min
      assert zoomed.max == whole.max

      # Zero is part of the run's range whatever the window shows, so the axis
      # is 0..20 and not 10..20.
      assert {zoomed.min, zoomed.max} == {0, 20}

      # The last two steps, at the heights the unzoomed chart gives them: only x
      # moved, because x is the only axis that was zoomed.
      assert [%{points: drawn}] = zoomed.lines
      assert [%{points: all}] = whole.lines

      assert Enum.map(drawn, &elem(&1, 1)) ==
               all |> Enum.take(-2) |> Enum.map(&elem(&1, 1))

      assert Enum.map(drawn, &elem(&1, 0)) == [0.0, zoomed.width * 1.0]
    end

    test "a rise of a fraction of a unit is a slope, not a cliff" do
      # A run whose evidence reaches 48: four hundredths of a unit of it is a
      # twentieth of one pixel of the chart's own height, so rounded to whole
      # units every one of those steps landed on the same ordinate and the rise
      # became a vertical jump at one place on the axis — the staircase in the
      # screenshot.
      chart = Chart.new(points([0, 0.04, 0.08, 48]), window: {0, 3}, playhead: 0)

      assert [%{polylines: [line]}] = chart.lines
      ys = line |> String.split(" ") |> Enum.map(&ordinate/1)

      # The three steps that creep, and nothing collapsed onto one of them.
      creeping = Enum.take(ys, 3)

      assert length(Enum.uniq(creeping)) == 3
      assert creeping == Enum.sort(creeping, :desc), "a rising line is drawn upwards"
      assert Enum.any?(creeping, &(&1 != trunc(&1))), "heights are not whole units"
    end

    test "every drawn stretch is an element of its own" do
      # A ten-object run cut at every episode is sixty polylines; sixty elements
      # with ten ids is an error the browser reports on every render.
      chart =
        Chart.many(
          [
            %{
              id: "object:mug",
              label: "mug",
              points: [
                %{step: 0, value: 1.0, episode: 0},
                %{step: 1, value: 2.0, episode: 1}
              ]
            },
            %{
              id: "object:bowl",
              label: "bowl",
              points: [
                %{step: 0, value: 3.0, episode: 0},
                %{step: 1, value: 4.0, episode: 1}
              ]
            }
          ],
          window: {0, 1}
        )

      ids = Enum.map(chart.polylines, & &1.id)

      assert length(ids) == 4
      assert length(Enum.uniq(ids)) == 4
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

      assert [%{polylines: [], points: []}] = chart.lines
      assert chart.polylines == []
      assert chart.hover == []
    end

    test "a line is cut at an episode boundary, not drawn across it" do
      # Evidence restarts at zero when the next episode begins. Joined up, that
      # reads as a fall nobody measured; cut, it reads as the episode ending.
      chart =
        Chart.new([
          %{step: 0, value: 4.0, episode: 0},
          %{step: 1, value: 6.0, episode: 0},
          %{step: 2, value: 0.5, episode: 1},
          %{step: 3, value: 3.0, episode: 1}
        ])

      assert [%{polylines: [first, second]}] = chart.lines
      assert first != "" and second != ""
      assert length(chart.polylines) == 2
    end

    test "a flat series is drawn across the middle" do
      chart = Chart.new(points([5, 5]), window: {0, 1}, playhead: 0)

      assert chart.min == chart.max

      assert [%{points: [first, second]}] = chart.lines
      # One height for both: a series with no range has no slope to draw.
      assert elem(first, 1) == elem(second, 1)

      # And it sits inside the plot, not on its edge.
      assert elem(first, 1) > 0 and elem(first, 1) < chart.height
    end

    test "a run of one step is a point in the plot's middle" do
      chart = Chart.new(points([7]), window: {0, 0}, playhead: 0)

      assert [%{points: [point]}] = chart.lines

      assert elem(point, 0) > 0 and elem(point, 0) < chart.width
      assert elem(point, 1) > 0 and elem(point, 1) < chart.height
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

    test "every series is a line, each in the colour its own object wears" do
      assert Enum.map(two_objects().lines, &{&1.label, &1.colour}) ==
               [{"mug", "#1f77b4"}, {"bowl", "#ff7f0e"}]
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
      chart = two_objects()

      assert Enum.map(samples, & &1.line) == ["mug", "mug", "mug", "bowl", "bowl", "bowl"]

      # The highest value is drawn at the top of the plot, one inset below the
      # edge, and the first step after the value labels.
      assert Enum.find(samples, &(&1.line == "bowl" and &1.step == 0)) == %{
               line: "bowl",
               x: 0.0,
               y: 4.0,
               step: 0,
               value: 8
             }
    end
  end

  describe "moving the playhead" do
    test "leaves the lines, the bands and the samples where they were" do
      series = [%{id: "mug", label: "mug", unit: "", points: points([1.0, 2.0, 3.0])}]
      chart = Chart.many(series, window: {0, 2}, playhead: 0)

      moved = Chart.with_playhead(chart, 2)

      # A drag of the slider moves one dashed line: everything else in a chart is
      # a function of the series and the window, and redrawing it per pixel of
      # drag is what made a slider in flight feel unlike a slider.
      assert moved.lines == chart.lines
      assert moved.polylines == chart.polylines
      assert moved.hover == chart.hover
      assert moved.bands == chart.bands
      assert moved.ticks == chart.ticks
      assert moved.playhead == 320
      assert chart.playhead == 0
    end
  end

  describe "a stretch of the line that lies flat" do
    test "is drawn by its ends, not by every step that sits on it" do
      # A step's value holds until the next step begins, so five steps that
      # reported the same number are one horizontal segment. On a run of 42 401
      # steps, 64 % of the points the page carried were of that kind — line that
      # is not there, in a page that has to arrive before it can be read.
      flat = drawn_points(Chart.new(points([4, 4, 4, 4, 4]), window: {0, 4}))
      climbs = drawn_points(Chart.new(points([1, 2, 3, 4, 5]), window: {0, 4}))

      assert [{start_x, height}, {end_x, height}] = flat

      # Two points, across the same span the same chart would be drawn between if
      # every step of it climbed.
      assert start_x == climbs |> hd() |> elem(0)
      assert end_x == climbs |> List.last() |> elem(0)
    end

    test "keeps every step of a climb" do
      assert length(drawn_points(Chart.new(points([1, 2, 3, 4]), window: {0, 3}))) == 4
    end

    test "ends where the climb away from it begins" do
      # The flat stretch is three points wide and the fourth step jumps: the line
      # has to reach the step before the jump, or the picture says the value held
      # for one step fewer than it did.
      flat = drawn_points(Chart.new(points([4, 4, 4, 9]), window: {0, 3}))
      climbs = drawn_points(Chart.new(points([1, 2, 3, 4]), window: {0, 3}))

      assert [{_start, height}, {flat_end, height}, {_jump, peak}] = flat

      assert flat_end == climbs |> Enum.at(2) |> elem(0)
      # Up is a smaller y: the climb leaves the flat line towards the top.
      assert peak < height
    end
  end

  describe "a run too long for the plot's own resolution" do
    # Five thousand steps across three hundred and twenty units of chart: every
    # unit holds fifteen samples, they are drawn on top of one another, and all
    # of them travel to the browser on every drawing a live page makes.
    defp five_thousand_steps, do: Enum.map(1..5000, &(&1 * 0.01))

    test "is drawn as many points as the plot can show, not one a step" do
      chart = Chart.many([series(five_thousand_steps(), "mug")])

      assert length(drawn_points(chart)) <= 4 * 320 + 2
    end

    test "still ends where the data does" do
      chart = Chart.many([series(five_thousand_steps(), "mug")])
      {last_x, _y} = chart |> drawn_points() |> List.last()

      assert last_x == chart.width
    end

    test "keeps every sample for the pointer, so a readout is exact" do
      chart = Chart.many([series(five_thousand_steps(), "mug")])

      assert length(chart.hover) == 5000
    end

    test "leaves a run the plot can show whole alone" do
      chart = Chart.many([series(Enum.map(1..500, &(&1 * 0.01)), "mug")])

      assert length(drawn_points(chart)) == 500
    end
  end
end
