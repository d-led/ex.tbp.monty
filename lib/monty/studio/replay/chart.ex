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

  alias Monty.Studio
  alias Monty.Studio.Replay

  @width 320
  @height 150

  # How finely the drawn path is sampled: this many samples to a unit of the plot,
  # which is more than the pixel a unit is drawn as. A stretch longer than the
  # plot can show is thinned to it (`thin/1`).
  @per_unit 4
  @max_drawn @width * @per_unit

  # Four labelled lines is what a plot this tall carries without crowding, and
  # the tolerance that keeps a value sitting exactly on a multiple from being
  # read as sitting just below it.
  @roughly_ticks 4
  @tick_epsilon 1.0e-9
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
    :zero,
    lines: [],
    bands: [],
    paths: [],
    hover: [],
    ticks: [],
    width: @width,
    height: @height
  ]

  @typedoc """
  One episode's stretch of the x axis, tinted.

  Evidence restarts at zero at every episode boundary, so a run's lines climb
  and drop in a rhythm. The bands are what makes that rhythm countable, and each
  wears the colour of the object its episode was about — the pyview dashboard's
  `buildEpisodeShapes` — so the tint names the object as well as the episode.
  """
  @type band :: %{episode: non_neg_integer(), x: float(), width: float(), colour: String.t()}

  @typedoc """
  One drawn series: where it was drawn, and what to call it.

  `colour` is the object's own, looked up by name (`Monty.Studio.Chart.colour/2`),
  so a line keeps its colour when the lines reorder themselves and it is the same
  colour as that object's episode bands.
  """
  @type line :: %{
          id: String.t(),
          label: String.t(),
          colour: String.t(),
          points: [{float(), float()}],
          stretches: [String.t()]
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
          paths: [%{colour: String.t(), id: String.t(), path: String.t()}],
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

    # The range of what is drawn, not of the whole run. Reading the whole run's
    # range meant a zoom was drawn against the tallest episode anywhere: an
    # episode that ran to 772 flattened the seventy-five that stayed under
    # sixty, and a stretch of them was a line at the bottom of the box with
    # nothing in it. Zero is always part of the range — evidence is a sum that
    # starts at zero, Monty's own dashboard draws the axis from there, and an
    # axis that began at the lowest line turns "40" into "forty above wherever
    # the weakest line happened to be" rather than forty steps of evidence. The
    # zero line is drawn wherever it is in range (`zero_y/2`), so the baseline
    # the lines are measured from is named.
    values = Enum.flat_map(visible, fn drawn -> Enum.map(drawn.points, & &1.value) end)
    {lowest, highest} = {Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)}

    # A series whose values never move is drawn across the middle of the plot
    # (`y/3` below), which needs its degenerate range kept as it is.
    {min, max} =
      if lowest == highest,
        do: {lowest, highest},
        else: {Kernel.min(lowest, 0), Kernel.max(highest, 0)}

    {lines, samples} =
      visible
      |> Enum.with_index()
      |> Enum.map(&line(&1, {from, to}, {min, max}))
      |> Enum.unzip()

    %__MODULE__{
      lines: lines,
      bands: bands(visible, {from, to}),
      paths: paths_of(lines),
      min: min,
      max: max,
      # Evidence always belongs to a range that contains zero — every episode
      # starts there — so the line it is measured from is drawn wherever the
      # axis admits it. A series that never comes near zero keeps an axis that
      # says so, rather than one stretched to a line nobody's data touches.
      zero: zero_y(min, max),
      from: from,
      to: to,
      hover: List.flatten(samples),
      ticks: ticks(min, max),
      playhead: playhead(Keyword.get(opts, :playhead), from, to)
    }
  end

  defp zero_y(min, max) when min <= 0 and max >= 0, do: Float.round(y(0, min, max), 2)
  defp zero_y(_min, _max), do: nil

  @doc """
  The same chart with the playhead moved to `step`.

  Everything else in a chart is a function of the series and the window: the
  lines, the bands, the axis, and the samples a hover reads. Only the dashed line
  moves when a reader drags the slider, so a drag moves that line — rebuilding a
  thousand points per pixel of drag was most of what a drag cost, and it is what
  made a slider in flight feel unlike a slider.
  """
  @spec with_playhead(t(), Replay.step_number() | nil) :: t()
  def with_playhead(%__MODULE__{from: from, to: to} = chart, step),
    do: %{chart | playhead: playhead(step, from, to)}

  # Labelled lines land on round numbers — one, two or five times a power of ten
  # — and the step is picked so the axis carries about four of them. Dividing the
  # range into equal parts instead labelled it -6.4, -1.4, 3.7, 8.7: numbers a
  # reader has to subtract to compare, and with zero between two of them rather
  # than on one, so the line evidence is measured from had no name.
  defp ticks(min, max) when max > min do
    step = tick_step(max - min)
    decimals = decimals(step)

    min
    |> multiples_inside(max, step)
    |> Enum.map(fn multiple ->
      value = multiple * step

      %{
        value: value,
        y: Float.round(y(value, min, max), 2),
        label: format(value, decimals)
      }
    end)
  end

  defp ticks(min, _max) do
    [%{value: min, y: Float.round(@height / 2, 2), label: format(min, whole?(min))}]
  end

  defp whole?(value) when value == trunc(value), do: 0
  defp whole?(_value), do: 2

  # The whole multiples of `step` inside the range. A step is never wider than
  # half the range, so there is always at least one of them.
  defp multiples_inside(min, max, step) do
    first = min |> Kernel./(step) |> Kernel.-(@tick_epsilon) |> Float.ceil() |> trunc()
    last = max |> Kernel./(step) |> Kernel.+(@tick_epsilon) |> Float.floor() |> trunc()

    Enum.to_list(first..last//1)
  end

  # The step a reader expects between labelled lines: 1, 2 or 5 times a power of
  # ten, and the smallest rung of that ladder that is not crowded.
  defp tick_step(span) do
    ideal = span / @roughly_ticks
    magnitude = :math.pow(10, Float.floor(:math.log10(ideal)))
    multiplier = ideal / magnitude

    cond do
      multiplier <= 1.0 -> magnitude
      multiplier <= 2.0 -> 2 * magnitude
      multiplier <= 5.0 -> 5 * magnitude
      true -> 10 * magnitude
    end
  end

  # As many decimals as the step needs: a step of 5 is written in whole numbers,
  # a step of 0.2 in one decimal, or two ticks would carry the same label.
  defp decimals(step) do
    step |> :math.log10() |> Float.floor() |> trunc() |> Kernel.*(-1) |> max(0)
  end

  defp format(value, 0), do: Integer.to_string(round(value))

  defp format(value, decimals),
    do: :erlang.float_to_binary(Float.round(value, decimals), decimals: decimals)

  # One `<path>` a line, each with an id of its own. A line cut at every episode
  # of a ten-object run is sixty stretches, and drawing each stretch as its own
  # element put six hundred nodes on the page for ten lines of ink — every patch
  # rebuilding them, and sixty elements under ten ids is an error the browser
  # reports on every render. The stretches are `M`s inside the path instead: the
  # pen lifts where the line was cut, so the picture is the same picture.
  defp paths_of(lines) do
    for {line, index} <- Enum.with_index(lines), path = path_of(line), path != "" do
      %{colour: line.colour, id: "replay-line-#{index}", path: path}
    end
  end

  defp path_of(line), do: Enum.map_join(line.stretches, " ", &("M " <> &1))

  # One band per episode the window can see, from the series that carries
  # episodes: consecutive steps of an episode are one stretch, and a band runs to
  # the step before the next episode begins so that neighbours tile without a gap.
  defp bands(series, {from, to}) do
    case episodes(series) do
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
      x: Float.round(x, 2),
      # The steps the band covers, so the band can be more than a tint: clicking
      # it is how a reader asks to look at one episode, and that needs both ends
      # rather than the pixels they were turned into.
      from: first,
      to: max(next_start - 1, first),
      # An episode reaches to the step the next one begins at — not to its own
      # last step, which would leave every episode a step short of the next.
      width: Float.round(min(x(next_start, from, to), @width) - x, 2),
      # A recorded moment keeps its episode but not the object that episode was
      # about, so each band takes a hue of its own from the episode's number.
      colour: Studio.Chart.colour(nil, hd(run).episode)
    }
  end

  # The series that carries episode numbers, if one does: a recorded run's does,
  # a probe's replay may not.
  defp episodes(series) do
    series
    |> Enum.map(fn drawn -> Enum.filter(drawn.points, &is_integer(&1[:episode])) end)
    |> Enum.find(&(&1 != []))
  end

  defp inside(points, {from, to}),
    do: Enum.filter(points, fn point -> Replay.inside?({from, to}, point.step) end)

  # One drawn line, and the samples a hover over it needs. Both come out of the
  # same walk so that the two can never disagree about where a step was drawn.
  #
  # Every sample is drawn. Keeping the extremes of each pixel column instead was
  # tried, to save the vertices a 24 000-step run spends on a 320-unit plot, and
  # it doubled every line: a column's lowest and highest sample are the same
  # x, so the path goes down and back up within one column and the stroke
  # retraces itself. A chart is read for its shape, and the shape was the thing
  # that got worse; the page's seconds came from computing the series, not from
  # drawing them.
  defp line({series, colour}, {from, to}, {min, max}) do
    points =
      Enum.map(series.points, fn point -> {x(point.step, from, to), y(point.value, min, max)} end)

    drawn = %{
      id: series.id,
      label: series.label,
      colour: Studio.Chart.colour(series.id, colour),
      points: points,
      stretches: stretch_points(series.points, points, {from, to})
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

  # One stretch's points per unbroken run the line was actually drawn on.
  # Evidence restarts at zero when an episode begins, and a theory the module
  # culled is simply gone — a line drawn across either gap is a fall or a run of
  # zeros nobody measured. A record that never kept episodes, and a theory that
  # lived throughout, still draw as one line.
  defp stretch_points(drawn_from, points, {from, to}) do
    drawn_from
    |> Enum.zip_with(points, fn point, xy -> {point[:episode], point.step, xy} end)
    |> stretches()
    |> Enum.map(fn run ->
      run |> to_the_edge(from, to) |> thin() |> Enum.map(&elem(&1, 2)) |> point_string()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  # A plot is `@width` units across however long the run is, so a stretch of five
  # thousand steps puts fifteen samples in every unit: they are drawn on top of
  # one another, and every one of them travels to the browser on every drawing a
  # live page makes. A stretch with more samples than the plot has room for is
  # thinned to the first of each quarter unit plus the point it really ends at —
  # monotone in x, so the stroke never retraces itself. Keeping a column's lowest
  # *and* highest was tried before and doubled every line: both sit at the same
  # x, and the retraced stroke looked worse than the sampling it saved.
  #
  # What a pointer reads is not thinned: `samples` below keeps every point, so a
  # hover still names the step under the cursor.
  defp thin(run) do
    if length(run) <= @max_drawn do
      run
    else
      (run |> Enum.chunk_by(&column/1) |> Enum.map(&hd/1)) ++ [List.last(run)]
    end
  end

  defp column({_episode, _step, {x, _y}}), do: trunc(x * @per_unit)

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

  defp point_string([]), do: ""
  # Two decimals, not whole numbers: the chart is 320 units wide for a run of
  # hundreds of steps, so a rounded ordinate is a cliff where the data has a
  # slope.
  #
  # A stretch of the line that lies flat needs two points, not the whole run of
  # them: a step's value holds until the next step begins, so any two steps that
  # reported the same number draw one horizontal segment however many points sit
  # on it. On a run of 42 401 steps that was 149 822 of the 235 168 points drawn
  # — 64 % of the page's 3.1 MB of coordinates as line that is not there. Only
  # points that share a height with the point on both sides are dropped, so a
  # slope of a hundredth of a unit still keeps every step it climbs by.
  defp point_string(points) do
    points
    |> Enum.map(fn {x, y} -> {round_to(x), round_to(y)} end)
    |> flat_stretches_to_their_ends()
    |> Enum.map_join(" ", fn {x, y} -> "#{x},#{y}" end)
  end

  # The first and last point of each run of one height, and everything that does
  # not share its height with the point before it.
  defp flat_stretches_to_their_ends(points) do
    points
    |> Enum.chunk_by(fn {_x, y} -> y end)
    |> Enum.flat_map(fn
      [only] -> [only]
      [first | _rest] = flat -> [first, List.last(flat)]
    end)
    |> Enum.dedup()
  end

  defp round_to(value), do: Float.round(value * 1.0, 2)
end
