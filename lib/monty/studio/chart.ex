defmodule Monty.Studio.Chart do
  @moduledoc """
  An evidence chart's geometry, computed once so a template only draws.

  A run's evidence is a sum of per-step increments, so the honest picture is one
  line per object against the step: it only ever climbs, and which lines climb
  fastest is the recognition being made. The numbers come from
  `Monty.Studio.Belief` — the learning module's own — so what is drawn is what
  the module held, not a summary of it.

  Two rules keep the chart from lying:

    * a step that did not report an object leaves a **gap**, not a straight line
      through it. Two steps that were never observed are not a step that was
      interpolated;
    * the vertical axis starts at zero, because evidence is a sum from zero and a
      truncated axis makes a small difference look like a large one.

  Coordinates are SVG user units, rounded, and every series carries its segments
  as ready-made `points` strings so the template has no arithmetic left to do.
  """

  alias Monty.Studio.Belief

  @margin_left 44
  @margin_bottom 22
  @margin_top 10
  @margin_right 12

  # How much room an episode's label needs before it is drawn: anything less and
  # the labels of a long run run into each other.
  @label_min_gap 24

  # The colours Monty's own dashboard draws with — `OBJECT_COLORS` in the pyview
  # experiment's `evidence-chart.js`, the tab10 palette — so an object is the same
  # colour on both charts. Looked up by name rather than by position, which is
  # what keeps a line's colour still while the lines reorder themselves.
  @object_colours %{
    "mug" => "#1f77b4",
    "bowl" => "#ff7f0e",
    "potted_meat_can" => "#2ca02c",
    "spoon" => "#d62728",
    "strawberry" => "#9467bd",
    "mustard_bottle" => "#8c564b",
    "dice" => "#e377c2",
    "golf_ball" => "#7f7f7f",
    "c_lego_duplo" => "#bcbd22",
    "banana" => "#17becf"
  }

  # The pyview dashboard's hue generator: consecutive indices are spread as far
  # apart as a circle allows, so an unnamed object is never mistaken for a
  # neighbour.
  @golden_angle 137.508

  defstruct width: 0,
            height: 0,
            margin_left: 44,
            margin_right: 12,
            margin_top: 10,
            margin_bottom: 22,
            x_min: 0,
            x_max: 0,
            y_min: 0.0,
            y_max: 1.0,
            zero: 0.0,
            series: [],
            labels: %{},
            legend: [],
            ticks: [],
            episode_bands: [],
            episode_starts: [],
            episode_labels: [],
            mlh: nil,
            mlh_colour: nil

  @typedoc """
  One step, as the chart reads it: which episode of the run it belongs to, which
  step of *that episode*, and what the module believed after it.

  The episode is not bookkeeping. Evidence is a sum that starts again at zero in
  every episode, so a chart drawn against the step alone would draw all of a
  run's episodes on top of the first one.
  """
  @type step :: {non_neg_integer(), non_neg_integer(), Belief.t()}

  @typedoc """
  One object's evidence over the run.

  `evidence` is `[{x, evidence}]` where `x` counts from the run's first step and
  does not restart with an episode: the samples the line is drawn from, which is
  every step when the plot is wide enough for them and a couple per column when
  it is not (`decimate/2`). `points` is `"x,y x,y …"` for an SVG
  `polyline`, one entry per contiguous run of steps: a graph that was reported on
  steps 1, 2 and 4 has two segments, the gap between 2 and 4 is visible, and an
  episode boundary is always a break — a line that continued from one episode's
  last evidence to the next one's zero would be a fall nobody measured.
  """
  @type series :: %{
          graph_id: String.t(),
          colour: String.t(),
          evidence: [{non_neg_integer(), float()}],
          points: [String.t()],
          last: {number(), number()}
        }

  @typedoc """
  Where an object was put the first time the chart saw it: the colour it wears and
  the place it holds in the legend.

  Assigned once and kept. A chart is rebuilt on every step, so anything derived
  from the drawing order would be recomputed — and the drawing order is
  worst-first, which moves whenever one object overtakes another. The caller
  hands this map back in with the next chart, so a reader's eye is never cheated:
  the blue line stays the same object and the third row of the legend stays the
  third object.
  """
  @type labels :: %{optional(String.t()) => %{colour: String.t(), position: non_neg_integer()}}

  @type t :: %__MODULE__{
          width: number(),
          height: number(),
          margin_left: number(),
          margin_right: number(),
          margin_top: number(),
          margin_bottom: number(),
          x_min: non_neg_integer(),
          x_max: non_neg_integer(),
          y_min: float(),
          y_max: float(),
          zero: number(),
          series: [series()],
          labels: labels(),
          legend: [series()],
          ticks: [%{value: float(), y: number(), label: String.t()}],
          episode_bands: [
            %{episode: non_neg_integer(), x: number(), width: number(), colour: String.t()}
          ],
          episode_starts: [%{episode: non_neg_integer(), x: number(), label: String.t()}],
          episode_labels: [%{episode: non_neg_integer(), x: number(), label: String.t()}],
          mlh: %{graph_id: String.t(), x: number(), y: number()} | nil,
          mlh_colour: String.t() | nil
        }

  @doc """
  How far the run goes: `{0, last}`, the whole of what a window can show.

  The page keeps this so zoom and pan have something to stay inside — a chart
  drawn for a window no longer knows how long the run is.
  """
  @spec extent([step()]) :: {non_neg_integer(), non_neg_integer()}
  def extent(steps) do
    {placed, _starts, _spans} = stack(steps)
    {0, last_step(placed)}
  end

  @doc """
  The chart of `steps` — `[{episode, step, belief}]`, in any order.

  Options: `:width` and `:height` in user units, `:objects` to draw only those
  graphs (default: every graph that was ever reported, worst first so the
  winner's line ends on top), and `:window` — `{from, to}` on the run's own x
  axis — to draw one stretch of it. A window wider than the run is the whole
  run, which is what a page that has been zoomed beyond either end should show.
  """
  @spec new([step()], keyword()) :: t()
  def new(steps, options \\ []) do
    width = Keyword.get(options, :width, 960)
    height = Keyword.get(options, :height, 300)

    {placed, starts, spans} = stack(steps)
    {from, to} = window(Keyword.get(options, :window), last_step(placed))
    episode_objects = Keyword.get(options, :episode_objects, %{})
    placed = within(placed, from, to)

    chart = %__MODULE__{width: width, height: height, x_min: from, x_max: to}

    # Every object's line, cut to what the plot can show as it is read — one
    # pass, and everything below works on a few thousand samples rather than on
    # every step the run ever took. The cut has to happen here, inside that
    # pass: building every step's sample for every object first and cutting
    # afterwards visited a thousand times more points than the picture can show,
    # which is what made a drawing of a long run cost a page most of a second
    # (`lines_by_object/2`).
    lines = lines_by_object(placed, chart)

    # Ranked worst first, so the object a run is converging on is drawn last and
    # its line ends on top of the others.
    ranked =
      Enum.sort_by(lines, fn {object_id, segments} -> {last_sample(segments), object_id} end)

    objects = Keyword.get(options, :objects) || Enum.map(ranked, &elem(&1, 0))

    # The colour and legend place every object was given when it first appeared,
    # extended by the ones that have appeared since — in the order the run
    # reported them, so a page that reloads and rebuilds from the record assigns
    # the same colours it assigned live.
    labels =
      assign_labels(
        Keyword.get(options, :labels, %{}),
        objects,
        lines
      )

    # The lowest and the highest value the chart will draw, in one pass: the
    # floor and the ceiling are read off the same fold so they cannot drift, and
    # a run of twenty thousand steps does not build two lists of every value to
    # throw them away. Cutting the samples down first cannot move either end: a
    # column keeps its lowest and its highest sample, so the lowest and the
    # highest of the drawing are the lowest and the highest of the run.
    {worst, best} = extreme_values(ranked)

    chart = %{
      chart
      | y_min: y_floor(worst),
        y_max: ceiling(best)
    }

    # Where the episodes begin, in the SVG's own units: a boundary line for every
    # one after the first, and a label only where there is room for one — a
    # seventy-seven-episode run would otherwise label itself into a grey smear.
    starts =
      starts
      |> Enum.filter(&(&1.x >= from and &1.x <= to))
      |> Enum.map(fn start -> %{start | x: rounded(x_coordinate(start.x, chart))} end)

    labelled = Enum.filter(starts, &there_is_room?(&1, starts))

    chart = %{
      chart
      | episode_starts: starts,
        episode_labels: labelled,
        episode_bands: bands(spans, from, to, chart, episode_objects)
    }

    series =
      objects
      |> Enum.map(fn object_id ->
        segments = Map.get(lines, object_id, [])

        %{
          graph_id: object_id,
          colour: Map.fetch!(labels, object_id).colour,
          evidence:
            segments
            |> Enum.concat()
            |> Enum.map(fn {_episode, x, evidence} -> {x, evidence} end),
          points:
            Enum.map(segments, fn segment ->
              Enum.map_join(segment, " ", &points_string(&1, chart))
            end),
          last: point(last_sample(segments) |> last_point(chart), chart)
        }
      end)
      |> Enum.reject(&(&1.evidence == []))

    legend = Enum.sort_by(series, &Map.fetch!(labels, &1.graph_id).position)

    mlh = mlh(placed, chart)

    # The marker wears the colour of the line it names, so "the answer" and "the
    # line that got there" are the same thing to look at.
    mlh_colour =
      Enum.find_value(series, colour(nil, 0), fn %{graph_id: id, colour: colour} ->
        if mlh && id == mlh.graph_id, do: colour
      end)

    %{
      chart
      | series: series,
        labels: labels,
        legend: legend,
        ticks: ticks(chart),
        # Evidence is measured from zero and can fall under it, so the line it is
        # measured from is drawn: the floor keeps zero inside the range, every
        # episode starts on it, and a reader comparing two objects is reading the
        # distance from it (`y_floor/1`).
        zero: rounded(y(0.0, chart)),
        mlh: mlh,
        mlh_colour: mlh_colour
    }
  end

  # Every object the chart has not seen before gets the next free legend place,
  # and with it the colour that place is worth — the same `colour/2` the palette
  # has always used. The newcomers are taken in the order the run reported them,
  # not in the drawing order, so a page rebuilt from the record assigns what a
  # page watching live assigned.
  defp assign_labels(labels, objects, lines) do
    newcomers =
      objects
      |> Enum.reject(&Map.has_key?(labels, &1))
      |> Enum.sort_by(fn object_id ->
        case Map.get(lines, object_id, []) do
          [[{_episode, x, _evidence} | _rest] | _segments] -> {x, object_id}
          _never_reported -> {:later, object_id}
        end
      end)

    next =
      labels
      |> Map.values()
      |> Enum.map(& &1.position)
      |> Enum.max(fn -> -1 end)
      |> Kernel.+(1)

    newcomers
    |> Enum.with_index(next)
    |> Enum.reduce(labels, fn {object_id, position}, labels ->
      Map.put(labels, object_id, %{colour: colour(object_id, position), position: position})
    end)
  end

  defp last_point({_episode, x, evidence}, _chart), do: {x, evidence}
  defp last_point(nil, chart), do: {chart.x_min, 0.0}

  # The stretch to draw, kept inside the run: a window that runs off either end
  # is the run, and one that is empty or back-to-front is the whole run rather
  # than a chart with nothing in it.
  defp window(nil, last), do: {0, last}

  defp window({from, to}, last) when is_number(from) and is_number(to) and from < to do
    from = from |> max(0) |> min(last)
    to = to |> max(0) |> min(last)

    if from < to, do: {from, to}, else: {0, last}
  end

  defp window(_nonsense, last), do: {0, last}

  defp within(placed, from, to),
    do: Enum.filter(placed, fn {_episode, x, _belief} -> x >= from and x <= to end)

  @doc """
  The colour of `name`, or a hue of its own when the name is not one Monty knows.

  The pyview dashboard's `getObjectColor`: a named object wears the colour of the
  tab10 palette, so its line and its episodes' bands are the same colour on both
  charts and a line does not change colour while the order of the lines does.
  Anything else — an episode whose object the chart was not told, a graph with no
  name — takes a hue from the golden angle, which spreads consecutive indices as
  far apart as a circle allows.
  """
  @spec colour(String.t() | nil, integer()) :: String.t()
  def colour(name, index \\ 0) do
    Map.get(@object_colours, name, golden_angle_colour(index))
  end

  defp golden_angle_colour(index) do
    "hsl(#{Float.round(:math.fmod(index * @golden_angle, 360.0), 3)}, 70%, 50%)"
  end

  # One band per episode the window can see, clipped to it, in the colour of the
  # object that episode was about — the pyview dashboard's `buildEpisodeShapes`.
  # An episode whose object this chart was not told takes a hue of its own, from
  # the episode's number so that a band keeps its colour while the window moves.
  defp bands(spans, from, to, chart, objects) do
    for %{episode: episode, from: first, to: last} <- spans,
        clipped_first = max(first, from),
        clipped_last = min(last, to),
        clipped_first < clipped_last do
      x = x_coordinate(clipped_first, chart)

      %{
        episode: episode,
        x: rounded(x),
        width: rounded(x_coordinate(clipped_last, chart) - x),
        colour: colour(Map.get(objects, episode), episode)
      }
    end
  end

  # Every object's line over the window, cut to the samples the plot can show.
  #
  # This is the one part of a drawing that costs what the run costs, because it
  # is the part that touches every step, and a page following a run asks for a
  # drawing four times a second. So it is one pass, taken a column at a time: a
  # column of the picture keeps the four samples a line at that width can still
  # be seen through, and the rest are never built at all. Building every step's
  # sample for every object and cutting afterwards — which is what this did —
  # visited a thousand times more points than the picture can show.
  #
  # The steps themselves decide two things the cutting cannot: a step an object
  # was not reported on leaves a hole in its line, and each column is a fresh
  # start for the extremes. So a column is read as runs — stretches of steps
  # reported one after another — and the runs of neighbouring columns are joined
  # back into one polyline where they meet.
  defp lines_by_object(placed, chart) do
    placed
    |> Enum.chunk_by(fn {_episode, x, _belief} -> column_of(x, chart) end)
    |> Enum.reduce(%{}, fn column, lines -> add_column(column, lines) end)
    |> Map.new(fn {object_id, runs} -> {object_id, segments(runs)} end)
  end

  # One column of the picture, read run by run: for each object, the stretches of
  # this column it was reported on, each cut to its first, lowest, highest and
  # last sample. Newest run first, because that is the one a step extends.
  defp add_column(column, lines) do
    column
    |> Enum.reduce(%{}, fn {episode, x, belief}, runs_of_column ->
      Enum.reduce(belief.graphs, runs_of_column, fn {object_id, graph}, runs_of_column ->
        sample = {episode, x, graph.max_evidence * 1.0}

        Map.update(
          runs_of_column,
          object_id,
          [{sample, sample, sample, sample}],
          fn runs -> extend_run(runs, sample) end
        )
      end)
    end)
    |> Enum.reduce(lines, fn {object_id, runs}, lines ->
      # A column's runs came newest first, and the columns come in step order, so
      # an object's runs are in step order once each column is turned round.
      Map.update(lines, object_id, Enum.reverse(runs), &(&1 ++ Enum.reverse(runs)))
    end)
  end

  defp extend_run([{first, low, high, previous} = run | earlier], sample) do
    if contiguous?(sample, previous),
      do: [{first, lower(low, sample), higher(high, sample), sample} | earlier],
      else: [run_of_one(sample), run | earlier]
  end

  defp run_of_one(sample), do: {sample, sample, sample, sample}

  # The polylines of one object: a new one wherever a step was not reported, and
  # the same one across a column boundary, because a column is how the picture is
  # read and not where the line breaks.
  defp segments([]), do: []

  defp segments([first_run | other_runs]) do
    polylines =
      Enum.chunk_while(
        other_runs,
        [first_run],
        fn run, [previous | _earlier] = line ->
          if contiguous?(first_sample(run), last_sample_of(previous)),
            do: {:cont, [run | line]},
            else: {:cont, Enum.reverse(line), [run]}
        end,
        fn line -> {:cont, Enum.reverse(line), []} end
      )

    Enum.map(polylines, fn line -> Enum.flat_map(line, &samples_of_run/1) end)
  end

  # What a line at this width can show of one run of a column: its first and its
  # last — the points the next column's line is drawn from — and its lowest and
  # its highest, which is what makes this a saving rather than a lie. In step
  # order, because a column is a set of samples and a polyline is a sequence.
  defp samples_of_run({first, low, high, last}) do
    [first, low, high, last]
    |> Enum.uniq()
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp first_sample({first, _low, _high, _last}), do: first
  defp last_sample_of({_first, _low, _high, last}), do: last

  # The column of the plot a step falls in. Two samples in one column are one
  # point on the line as it is drawn, which is why a column keeps only what can
  # be seen of it.
  defp column_of(x, chart), do: x_coordinate(x, chart) |> round()

  # The last sample drawn, and `nil` for a line with nothing on it: the ranking
  # of the lines and the page's legend both start from it.
  defp last_sample([]), do: nil
  defp last_sample(segments), do: segments |> List.last() |> List.last()

  # Two samples are on one line when they are the same episode and the step after
  # the last. An episode boundary is a break by definition: evidence is a sum that
  # restarts at zero, so a line drawn through the boundary would show the second
  # episode's climb as the first one's, on an axis longer than either has.
  defp contiguous?({episode, x, _evidence}, {episode, previous, _previous_evidence}),
    do: x == previous + 1

  defp contiguous?(_sample, _previous), do: false

  # The lower of two samples, and the higher: they are the two points of a column
  # a line drawn at this width still shows.
  defp lower({_episode, _x, current} = held, {_other, _at, candidate} = sample),
    do: if(candidate < current, do: sample, else: held)

  defp higher({_episode, _x, current} = held, {_other, _at, candidate} = sample),
    do: if(candidate > current, do: sample, else: held)

  # Every step, on the run's own x axis.
  #
  # An episode restarts its step counter, so `{episode 2, step 0}` and
  # `{episode 1, step 0}` are different moments of the same run. The episodes are
  # laid end to end: the first one from 0, each next one where the one before it
  # ended. That is what makes the drop back to zero — the thing an episode
  # boundary *is* — visible instead of hidden under the first episode's line.
  defp stack(steps) do
    {chunks, starts, spans, _next} =
      steps
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.reduce({[], [], [], 0}, fn {episode, of_episode}, {chunks, starts, spans, base} ->
        of_episode = Enum.sort_by(of_episode, &elem(&1, 1))
        first = of_episode |> hd() |> elem(1)
        last = of_episode |> List.last() |> elem(1)

        points =
          for {_episode, step, belief} <- of_episode, do: {episode, base + step - first, belief}

        start = %{episode: episode, x: base, label: "ep #{episode + 1}"}
        span = %{episode: episode, from: base, to: base + (last - first)}

        # An episode is built whole and put aside. Appending it to what the
        # episodes before it made copies that list once per episode: a run of
        # eighty episodes copied twenty thousand points eighty times, which was
        # most of what a drawing cost — and a page draws four times a second.
        #
        # The next episode begins one step after this one ends. Two episodes that
        # shared a column were two climbs drawn at one x — one continuing the
        # other's line, which is the thing this chart exists not to do — and the
        # break between them is a break either way, so nothing is lost by the step
        # of room it takes.
        {[points | chunks], [start | starts], [span | spans], base + (last - first) + 1}
      end)

    {chunks |> Enum.reverse() |> Enum.concat(), Enum.reverse(starts), Enum.reverse(spans)}
  end

  defp last_step([]), do: 1
  defp last_step(placed), do: placed |> Enum.map(&elem(&1, 1)) |> Enum.max()

  # A label is legible when the episode after it is far enough to the right; the
  # first episode always gets one, because it is the axis' own start.
  defp there_is_room?(%{episode: 0}, _starts), do: true

  defp there_is_room?(start, starts) do
    case Enum.find(starts, &(&1.episode == start.episode + 1)) do
      nil -> true
      next -> next.x - start.x >= @label_min_gap
    end
  end

  # The lowest and the highest evidence the chart draws, over every object's
  # points. An empty chart has both at zero, which `ceiling/1` turns into a scale.
  defp extreme_values(ranked) do
    Enum.reduce(ranked, {nil, nil}, fn {_graph_id, segments}, {worst, best} ->
      Enum.reduce(segments, {worst, best}, fn segment, {worst, best} ->
        Enum.reduce(segment, {worst, best}, fn {_episode, _x, evidence}, {low, high} ->
          {if(low == nil or evidence < low, do: evidence, else: low),
           if(high == nil or evidence > high, do: evidence, else: high)}
        end)
      end)
    end)
  end

  # Rounded up to a whole number so the axis has a unit to label, and never zero:
  # an empty chart still needs a scale to divide by.
  defp ceiling(nil), do: 1.0

  defp ceiling(best), do: max(Float.ceil(best), 1.0)

  # Zero, unless the evidence went below it. A hypothesis is penalised as well as
  # rewarded, so a run's evidence really can fall under zero, and an axis pinned
  # at zero projected those points below the plot area — the lines then drew
  # themselves across the x axis labels, which is a chart lying about its own
  # scale. The floor is a whole number at or below the lowest point, so ticks
  # stay round and the baseline is still named.
  defp y_floor(nil), do: 0.0

  defp y_floor(worst), do: min(Float.floor(worst), 0.0)

  defp points_string({_episode, x, evidence}, chart) do
    {px, py} = point({x, evidence}, chart)
    "#{px},#{py}"
  end

  defp point({x, evidence}, chart) do
    {rounded(x_coordinate(x, chart)), rounded(y(evidence, chart))}
  end

  defp x_coordinate(x, chart) do
    span = max(chart.x_max - chart.x_min, 1)
    @margin_left + (x - chart.x_min) / span * (chart.width - @margin_left - @margin_right)
  end

  defp y(evidence, chart) do
    chart.height -
      @margin_bottom - (evidence - chart.y_min) / (chart.y_max - chart.y_min) * plot_height(chart)
  end

  defp plot_height(chart), do: chart.height - @margin_top - @margin_bottom

  defp rounded(value), do: Float.round(value * 1.0, 2)

  # How many labels an axis may carry before the labels are the chart. A run of
  # one hundred and twelve units of evidence at one tick a unit drew a hundred
  # and thirteen numbers into two hundred and sixty pixels: a grey wall, and the
  # line behind it unreadable.
  @max_ticks 8

  # The steps a reader can divide by in their head: one, two, five, and their
  # tens. Evidence is a sum of increments around one, so a step of three and a
  # half would be a number nobody asked for.
  @tick_steps [1, 2, 5]

  # One tick per step, from the floor — which is zero unless the data went below
  # it, because labelling from zero whatever the range was left the part under
  # zero unnamed, and a reader could not tell how far down a line had gone.
  defp ticks(chart) do
    step = tick_step(chart.y_max - chart.y_min)
    first = (chart.y_min / step) |> Float.ceil() |> trunc() |> Kernel.*(step)

    first
    |> Stream.iterate(&(&1 + step))
    |> Enum.take_while(&(&1 <= chart.y_max))
    |> Enum.map(fn value ->
      %{value: value * 1.0, y: rounded(y(value * 1.0, chart)), label: Integer.to_string(value)}
    end)
  end

  # The smallest round step that keeps the axis to `@max_ticks` labels. Every
  # step is a whole number, so every label is one.
  defp tick_step(span) do
    Enum.find(round_steps(), fn step -> span / step + 1 <= @max_ticks end) ||
      List.last(round_steps())
  end

  # Ascending, so the first one that fits is the finest that does.
  defp round_steps do
    for decade <- 0..12, base <- @tick_steps, do: base * Integer.pow(10, decade)
  end

  # Where the module's most likely hypothesis sits — the answer, on the line it
  # belongs to, at the step it was held.
  defp mlh([], _chart), do: nil

  defp mlh(placed, chart) do
    {_episode, x, belief} = List.last(placed)

    case belief.mlh do
      nil ->
        nil

      mlh ->
        %{
          graph_id: mlh.graph_id,
          x: rounded(x_coordinate(x, chart)),
          y: rounded(y(mlh.evidence * 1.0, chart))
        }
    end
  end
end
