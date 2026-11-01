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

  # Enough colours to tell a handful of objects apart before they repeat; a
  # recognition run is usually between one and ten objects, and a line's identity
  # is also carried by the legend beside it.
  @palette [
    "#2563eb",
    "#dc2626",
    "#16a34a",
    "#d97706",
    "#7c3aed",
    "#0891b2",
    "#db2777",
    "#4b5563"
  ]
  # How much room an episode's label needs before it is drawn: anything less and
  # the labels of a long run run into each other.
  @label_min_gap 24
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
            series: [],
            ticks: [],
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
  does not restart with an episode. `points` is `"x,y x,y …"` for an SVG
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
          series: [series()],
          ticks: [%{value: float(), y: number(), label: String.t()}],
          episode_starts: [%{episode: non_neg_integer(), x: number(), label: String.t()}],
          episode_labels: [%{episode: non_neg_integer(), x: number(), label: String.t()}],
          mlh: %{graph_id: String.t(), x: number(), y: number()} | nil,
          mlh_colour: String.t() | nil
        }

  @doc """
  The chart of `steps` — `[{episode, step, belief}]`, in any order.

  Options: `:width` and `:height` in user units, and `:objects` to draw only
  those graphs (default: every graph that was ever reported, worst first so the
  winner's line ends on top).
  """
  @spec new([step()], keyword()) :: t()
  def new(steps, options \\ []) do
    width = Keyword.get(options, :width, 960)
    height = Keyword.get(options, :height, 300)

    {placed, starts} = stack(steps)

    # Ranked worst first, so the object a run is converging on is drawn last and
    # its line ends on top of the others.
    ranked = evidence_by_object(placed)
    points_by_object = Map.new(ranked)
    objects = Keyword.get(options, :objects) || Enum.map(ranked, &elem(&1, 0))

    chart = %__MODULE__{
      width: width,
      height: height,
      x_min: 0,
      x_max: last_step(placed),
      y_max: ceiling(Enum.map(ranked, fn {_id, points} -> Enum.map(points, &elem(&1, 2)) end))
    }

    # Where the episodes begin, in the SVG's own units: a boundary line for every
    # one after the first, and a label only where there is room for one — a
    # seventy-seven-episode run would otherwise label itself into a grey smear.
    starts = Enum.map(starts, fn start -> %{start | x: rounded(x_coordinate(start.x, chart))} end)
    labelled = Enum.filter(starts, &there_is_room?(&1, starts))
    chart = %{chart | episode_starts: starts, episode_labels: labelled}

    series =
      objects
      |> Enum.with_index()
      |> Enum.map(fn {object_id, index} ->
        points = Map.get(points_by_object, object_id, [])

        %{
          graph_id: object_id,
          colour: Enum.at(@palette, rem(index, length(@palette))),
          evidence: Enum.map(points, fn {_episode, x, evidence} -> {x, evidence} end),
          points: segments(points, chart),
          last: point(List.last(points) |> last_point(chart), chart)
        }
      end)
      |> Enum.reject(&(&1.evidence == []))

    mlh = mlh(placed, chart)

    # The marker wears the colour of the line it names, so "the answer" and "the
    # line that got there" are the same thing to look at.
    mlh_colour =
      Enum.find_value(series, @palette |> hd(), fn %{graph_id: id, colour: colour} ->
        if mlh && id == mlh.graph_id, do: colour
      end)

    %{chart | series: series, ticks: ticks(chart), mlh: mlh, mlh_colour: mlh_colour}
  end

  defp last_point({_episode, x, evidence}, _chart), do: {x, evidence}
  defp last_point(nil, chart), do: {chart.x_min, 0.0}

  # One object's reported evidence, per step, in the order the module listed the
  # objects on the last step it reported them — so the line the run is chasing is
  # drawn last and ends on top.
  defp evidence_by_object(placed) do
    by_object =
      Enum.reduce(placed, %{}, fn {episode, x, belief}, acc ->
        Enum.reduce(belief.graphs, acc, fn {graph_id, graph}, acc ->
          Map.update(
            acc,
            graph_id,
            [{episode, x, graph.max_evidence * 1.0}],
            &[{episode, x, graph.max_evidence * 1.0} | &1]
          )
        end)
      end)

    by_object
    |> Map.new(fn {graph_id, points} -> {graph_id, Enum.sort(points)} end)
    |> Enum.sort_by(fn {graph_id, points} -> {List.last(points), graph_id} end)
  end

  # Every step, on the run's own x axis.
  #
  # An episode restarts its step counter, so `{episode 2, step 0}` and
  # `{episode 1, step 0}` are different moments of the same run. The episodes are
  # laid end to end: the first one from 0, each next one where the one before it
  # ended. That is what makes the drop back to zero — the thing an episode
  # boundary *is* — visible instead of hidden under the first episode's line.
  defp stack(steps) do
    {placed, starts, _next} =
      steps
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.reduce({[], [], 0}, fn {episode, of_episode}, {placed, starts, base} ->
        of_episode = Enum.sort_by(of_episode, &elem(&1, 1))
        first = of_episode |> hd() |> elem(1)
        last = of_episode |> List.last() |> elem(1)

        points =
          for {_episode, step, belief} <- of_episode, do: {episode, base + step - first, belief}

        start = %{episode: episode, x: base, label: "ep #{episode + 1}"}
        # The next episode begins on this one's last step, not after it: a gap
        # between them is a step the chart would be claiming nobody reported.
        {placed ++ points, [start | starts], base + (last - first)}
      end)

    {placed, Enum.reverse(starts)}
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

  # Rounded up to a whole number so the axis has a unit to label, and never zero:
  # an empty chart still needs a scale to divide by.
  defp ceiling([]), do: 1.0

  defp ceiling(all_evidence) do
    best = all_evidence |> List.flatten() |> Enum.max(fn -> 0.0 end)
    max(Float.ceil(best), 1.0)
  end

  # A segment per contiguous run of steps: an object reported on 1, 2 and 4 has
  # two polylines, and the missing step 3 stays missing. An episode boundary is
  # always a break, even though the run's x carries on: the evidence did start
  # again at zero there, and a line joining the two would be a fall nobody saw.
  defp segments(points, chart) do
    points
    |> Enum.reduce([], fn {episode, _x, _evidence} = point, segments ->
      case segments do
        [{same_episode, run} | earlier] ->
          if episode == same_episode and contiguous?(point, List.last(run)),
            do: [{same_episode, run ++ [point]} | earlier],
            else: [{episode, [point]} | segments]

        [] ->
          [{episode, [point]}]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {_episode, run} -> Enum.map_join(run, " ", &points_string(&1, chart)) end)
  end

  defp contiguous?({_episode, x, _evidence}, {_same_episode, previous, _previous_evidence}),
    do: x == previous + 1

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

  # One tick per whole unit of evidence, which is the resolution a reader needs:
  # evidence is a sum of increments around one, so halves would be noise.
  defp ticks(chart) do
    for value <- 0..trunc(chart.y_max)//1 do
      %{value: value * 1.0, y: rounded(y(value * 1.0, chart)), label: "#{value}"}
    end
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
