defmodule Monty.Studio.Replay.Chart do
  @moduledoc """
  Series drawn as lines over one pair of axes, and where the playhead sits.

  The geometry is here rather than in HEEx for the same reason the wiring
  diagram's is: "zoomed into steps 3 to 7, the line should enter at the left
  edge" is an assertion, not a matter of taste.

  Zoom moves the **x axis only**. The value axis is the run's, so a line keeps
  the shape it has while a reader walks along it, and two windows can be
  compared: a scale per window redrew every line against a new axis on every
  click, so the same line looked like a different one and the picture was not of
  anything. A series whose values never move still needs a scale, so a flat run
  is drawn across the middle rather than at the top or the foot.

  Coordinates come out as floats. A run of 546 steps drawn in 320 units puts
  four steps in a pixel and a whole evidence unit in little more than one, so a
  rounded ordinate turns every small rise into a cliff: the line reads as a
  staircase that the data does not have.

  One chart holds many lines because that is how an episode is read: every object
  a learning module still had a graph for, on the same axis. The moment one line
  climbs away from the rest is the recognition, and it is visible as a shape
  rather than as a table to compare.
  """

  alias Monty.Studio.Chart, as: EvidenceChart
  alias Monty.Studio.Replay

  @width 320
  @height 150
  @inset 4

  # The plot uses the whole box: the value labels are HTML beside it, not SVG
  # text inside it. Text inside a chart drawn with `preserveAspectRatio="none"`
  # is stretched with the geometry — twice as wide as it is tall, at this
  # chart's shape — and a gutter in user units costs that many stretched pixels
  # of line. Beside the plot, a label is a label, and the plot loses no width.

  @enforce_keys [:lines, :min, :max, :from, :to]
  defstruct [
    :min,
    :max,
    :from,
    :to,
    :playhead,
    lines: [],
    bands: [],
    polylines: [],
    hover: [],
    ticks: [],
    width: @width,
    height: @height
  ]

  @typedoc """
  One episode's stretch of the x axis, tinted.

  Evidence restarts at zero at every episode boundary, so a run's lines climb
  and drop in a rhythm. The bands are what makes that rhythm countable: without
  them the drops are falls nobody measured.
  """
  @type band :: %{episode: non_neg_integer(), x: float(), width: float(), colour: String.t()}

  @typedoc """
  One drawn series: where it was drawn, and what to call it.

  `colour` is an index rather than a colour: the chart does not know what a page
  paints with, it only knows that two lines must not be given the same one.
  """
  @type line :: %{
          id: String.t(),
          label: String.t(),
          colour: non_neg_integer(),
          points: [{float(), float()}],
          polylines: [String.t()]
        }

  @typedoc """
  One drawn point: where it sits, what it is worth, and which line it is on.

  Hovering has to name the line under the pointer and its value, and neither
  survives scaling — the drawn points are pixels. So every drawn point brings its
  step, its value and its line along.
  """
  @type sample :: %{
          line: String.t(),
          x: float(),
          y: float(),
          step: integer(),
          value: number()
        }

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          lines: [line()],
          bands: [band()],
          polylines: [%{colour: non_neg_integer(), id: String.t(), points: String.t()}],
          min: number(),
          max: number(),
          from: number(),
          to: number(),
          playhead: float() | nil,
          hover: [sample()],
          ticks: [%{value: number(), y: float(), label: String.t()}]
        }

  @doc """
  Draws one series inside a window.

  Options: `:window` (`{from, to}`), `:playhead` (the step being replayed), and
  `:label` for the series' name. Steps outside the window are not drawn: the
  window is what the reader asked to look at.
  """
  @spec new([Replay.point()], keyword()) :: t()
  def new(points, opts \\ []) do
    many([%{id: "series", label: Keyword.get(opts, :label, ""), points: points}], opts)
  end

  @doc """
  Draws several series on one pair of axes.

  Each series is a map with `:id`, `:label` and `:points`, in the order they are
  to be painted. The window and the value range are shared, which is the whole
  point: two lines scaled separately would each look like the winner.
  """
  @spec many([%{id: String.t(), label: String.t(), points: [Replay.point()]}], keyword()) :: t()
  def many(series, opts \\ []) do
    {from, to} = window(series, Keyword.get(opts, :window))
    visible = Enum.map(series, &%{&1 | points: inside(&1.points, {from, to})})

    # The run's own range, not the window's: see the moduledoc.
    values = Enum.flat_map(series, fn drawn -> Enum.map(drawn.points, & &1.value) end)
    {min, max} = {Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)}

    {lines, samples} =
      visible
      |> Enum.with_index()
      |> Enum.map(&line(&1, {from, to}, {min, max}))
      |> Enum.unzip()

    %__MODULE__{
      lines: lines,
      bands: bands(visible, {from, to}),
      polylines: polylines_of(lines),
      min: min,
      max: max,
      from: from,
      to: to,
      hover: List.flatten(samples),
      ticks: ticks(min, max),
      playhead: playhead(Keyword.get(opts, :playhead), from, to)
    }
  end

  # Four values across the axis, always including both ends, in the fewest
  # decimals that tell them apart: the numbers a reader uses to say how far one
  # line is above another.
  defp ticks(min, max) when max > min do
    steps = 3

    for index <- 0..steps do
      value = min + (max - min) * index / steps
      %{value: value, y: Float.round(y(value, min, max), 2), label: number(value)}
    end
  end

  defp ticks(min, _max), do: [%{value: min, y: Float.round(@height / 2, 2), label: number(min)}]

  defp number(value) when value == trunc(value), do: Integer.to_string(trunc(value))
  defp number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  # Every line's stretches, flat: a template draws one `<polyline>` per stretch,
  # and how many stretches a line has is the chart's business, not the page's.
  # Each carries an id of its own — a line cut at every episode of a ten-object
  # run is sixty polylines, and sixty elements with ten ids is an error the
  # browser reports on every render.
  defp polylines_of(lines) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, line_index} ->
      line.polylines
      |> Enum.with_index()
      |> Enum.map(fn {points, stretch} ->
        %{
          colour: line.colour,
          id: "replay-line-#{line_index}-#{stretch}",
          points: points
        }
      end)
    end)
  end

  # One band per episode the window can see, from the series that carries
  # episodes: consecutive steps of an episode are one stretch, and a band runs to
  # the step before the next episode begins so that neighbours tile without a gap.
  defp bands(series, {from, to}) do
    episodes =
      series
      |> Enum.map(fn drawn -> Enum.filter(drawn.points, &is_integer(&1[:episode])) end)
      |> Enum.find(&(&1 != []))

    case episodes do
      nil ->
        []

      points ->
        runs = Enum.chunk_by(points, & &1.episode)
        starts = Enum.map(runs, fn run -> hd(run).step end) ++ [to + 1]

        runs
        |> Enum.with_index()
        |> Enum.map(fn {run, index} -> band(run, Enum.at(starts, index + 1), {from, to}) end)
        |> Enum.reject(&(&1.width <= 0))
    end
  end

  defp band(run, next_start, {from, to}) do
    first = hd(run).step
    x = x(first, from, to)

    %{
      episode: hd(run).episode,
      x: x,
      # An episode reaches to the step the next one begins at — not to its own
      # last step, which would leave every episode a step short of the next.
      width: min(x(next_start, from, to), @width) - x,
      colour: EvidenceChart.band_colour(hd(run).episode)
    }
  end

  defp inside(points, {from, to}),
    do: Enum.filter(points, fn point -> Replay.inside?({from, to}, point.step) end)

  # One drawn line, and the samples a hover over it needs. Both come out of the
  # same walk so that the two can never disagree about where a step was drawn.
  defp line({series, colour}, {from, to}, {min, max}) do
    points =
      Enum.map(series.points, fn point -> {x(point.step, from, to), y(point.value, min, max)} end)

    drawn = %{
      id: series.id,
      label: series.label,
      colour: colour,
      points: points,
      polylines: polylines(series.points, points, {from, to})
    }

    samples =
      Enum.zip_with(series.points, points, fn point, {x, y} ->
        %{line: series.label, x: x, y: y, step: point.step, value: point.value}
      end)

    {drawn, samples}
  end

  # The window is the steps every series has, so a series that starts later does
  # not shorten the axis the others are drawn on.
  defp window(_series, {from, to}), do: {from, to}

  defp window(series, _default) do
    case series |> Enum.flat_map(fn drawn -> Enum.map(drawn.points, & &1.step) end) do
      [] -> {0, 0}
      steps -> {Enum.min(steps), Enum.max(steps)}
    end
  end

  defp x(_step, from, to) when to == from, do: middle_x()

  defp x(step, from, to), do: (step - from) / (to - from) * @width

  defp middle_x, do: @width / 2

  defp y(_value, min, max) when max == min, do: middle_y()

  defp y(value, min, max) do
    bottom = @height - @inset
    top = @inset
    bottom - (value - min) / (max - min) * (bottom - top)
  end

  defp middle_y, do: @height / 2

  defp playhead(nil, _from, _to), do: nil
  defp playhead(step, from, to), do: x(step, from, to)

  # One polyline per stretch the line was actually drawn on. Evidence restarts at
  # zero when an episode begins, and a theory the module culled is simply gone —
  # a line drawn across either gap is a fall or a run of zeros nobody measured.
  # A record that never kept episodes, and a theory that lived throughout, still
  # draw as one line.
  defp polylines(drawn_from, points, {from, to}) do
    drawn_from
    |> Enum.zip_with(points, fn point, xy -> {point[:episode], point.step, xy} end)
    |> stretches()
    |> Enum.map(fn run ->
      run |> to_the_edge(from, to) |> Enum.map(&elem(&1, 2)) |> polyline()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # A step's value holds until the next step begins, so a stretch is drawn to the
  # edge of the step it was last seen in. Without that the line stops at its last
  # sample and leaves a band-wide gap of tint beside it, which reads as a missing
  # step rather than as an episode ending.
  defp to_the_edge(run, from, to) do
    {_episode, last_step, {last_x, last_y}} = List.last(run)
    edge = min(x(last_step + 1, from, to), @width)

    if edge > last_x, do: run ++ [{nil, nil, {edge, last_y}}], else: run
  end

  # The stretches a line is one piece on: consecutive steps of one episode. A new
  # point starts a stretch wherever the episode changes — evidence restarts at
  # zero there — or a step is missing, which is a theory the module culled and
  # has nothing to report about.
  defp stretches(points) do
    points
    |> Enum.reduce([], fn {episode, step, _xy} = point, stretches ->
      case stretches do
        [[{same, previous, _} | _] = run | earlier] ->
          if episode == same and step == previous + 1,
            do: [[point | run] | earlier],
            else: [[point], run | earlier]

        [] ->
          [[point]]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
  end

  defp polyline([]), do: ""

  # Two decimals, not whole numbers: the chart is 320 units wide for a run of
  # hundreds of steps, so a rounded ordinate is a cliff where the data has a
  # slope.
  defp polyline(points),
    do: points |> Enum.map_join(" ", fn {x, y} -> "#{round_to(x)},#{round_to(y)}" end)

  defp round_to(value), do: Float.round(value * 1.0, 2)
end
