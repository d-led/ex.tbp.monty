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

  defstruct width: 0,
            height: 0,
            x_min: 0,
            x_max: 0,
            y_min: 0.0,
            y_max: 1.0,
            series: [],
            ticks: [],
            mlh: nil,
            mlh_colour: nil

  @typedoc """
  One object's evidence over the steps it was reported in.

  `points` is `"x,y x,y …"` for an SVG `polyline`, one entry per contiguous run
  of steps: a graph that was reported on steps 1, 2 and 4 has two segments, and
  the gap between 2 and 4 is visible.
  """
  @type series :: %{
          graph_id: String.t(),
          colour: String.t(),
          evidence: [{pos_integer(), float()}],
          points: [String.t()],
          last: {number(), number()}
        }

  @type t :: %__MODULE__{
          width: number(),
          height: number(),
          x_min: non_neg_integer(),
          x_max: non_neg_integer(),
          y_min: float(),
          y_max: float(),
          series: [series()],
          ticks: [%{value: float(), y: number(), label: String.t()}],
          mlh: %{graph_id: String.t(), x: number(), y: number()} | nil,
          mlh_colour: String.t() | nil
        }

  @doc """
  The chart of `steps` — `[{step, belief}]`, oldest first.

  Options: `:width` and `:height` in user units, and `:objects` to draw only
  those graphs (default: every graph that was ever reported, worst first so the
  winner's line ends on top).
  """
  @spec new([{pos_integer(), Belief.t()}], keyword()) :: t()
  def new(steps, options \\ []) do
    width = Keyword.get(options, :width, 640)
    height = Keyword.get(options, :height, 240)

    # Ranked worst first, so the object a run is converging on is drawn last and
    # its line ends on top of the others.
    ranked = evidence_by_object(steps)
    points_by_object = Map.new(ranked)
    objects = Keyword.get(options, :objects) || Enum.map(ranked, &elem(&1, 0))

    chart = %__MODULE__{
      width: width,
      height: height,
      x_min: first_step(steps),
      x_max: last_step(steps),
      y_max: ceiling(Enum.map(ranked, fn {_id, points} -> Enum.map(points, &elem(&1, 1)) end))
    }

    series =
      objects
      |> Enum.with_index()
      |> Enum.map(fn {object_id, index} ->
        points = Map.get(points_by_object, object_id, [])

        %{
          graph_id: object_id,
          colour: Enum.at(@palette, rem(index, length(@palette))),
          evidence: points,
          points: segments(points, chart),
          last: point(List.last(points) || {chart.x_min, 0.0}, chart)
        }
      end)
      |> Enum.reject(&(&1.evidence == []))

    mlh = mlh(steps, chart)

    # The marker wears the colour of the line it names, so "the answer" and "the
    # line that got there" are the same thing to look at.
    mlh_colour =
      Enum.find_value(series, @palette |> hd(), fn %{graph_id: id, colour: colour} ->
        if mlh && id == mlh.graph_id, do: colour
      end)

    %{chart | series: series, ticks: ticks(chart), mlh: mlh, mlh_colour: mlh_colour}
  end

  # One object's reported evidence, per step, in the order the module listed the
  # objects on the last step it reported them — so the line the run is chasing is
  # drawn last and ends on top.
  defp evidence_by_object(steps) do
    by_object =
      Enum.reduce(steps, %{}, fn {step, belief}, acc ->
        Enum.reduce(belief.graphs, acc, fn {graph_id, graph}, acc ->
          Map.update(
            acc,
            graph_id,
            [{step, graph.max_evidence * 1.0}],
            &[{step, graph.max_evidence * 1.0} | &1]
          )
        end)
      end)

    by_object
    |> Map.new(fn {graph_id, points} -> {graph_id, Enum.sort(points)} end)
    |> Enum.sort_by(fn {graph_id, points} -> {List.last(points), graph_id} end)
  end

  defp first_step([]), do: 0
  defp first_step(steps), do: steps |> Enum.map(&elem(&1, 0)) |> Enum.min()

  defp last_step([]), do: 1
  defp last_step(steps), do: steps |> Enum.map(&elem(&1, 0)) |> Enum.max()

  # Rounded up to a whole number so the axis has a unit to label, and never zero:
  # an empty chart still needs a scale to divide by.
  defp ceiling([]), do: 1.0

  defp ceiling(all_evidence) do
    best = all_evidence |> List.flatten() |> Enum.max(fn -> 0.0 end)
    max(Float.ceil(best), 1.0)
  end

  # A segment per contiguous run of steps: an object reported on 1, 2 and 4 has
  # two polylines, and the missing step 3 stays missing.
  defp segments(points, chart) do
    points
    |> Enum.reduce([], fn {step, _evidence} = point, segments ->
      case segments do
        [run | earlier] ->
          if step == previous_step(List.last(run)) + 1,
            do: [run ++ [point] | earlier],
            else: [[point] | segments]

        [] ->
          [[point]]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn run -> Enum.map_join(run, " ", &points_string(&1, chart)) end)
  end

  defp previous_step({step, _evidence}), do: step

  defp points_string({step, evidence}, chart) do
    {x, y} = point({step, evidence}, chart)
    "#{x},#{y}"
  end

  defp point({step, evidence}, chart) do
    {rounded(x(step, chart)), rounded(y(evidence, chart))}
  end

  defp x(step, chart) do
    span = max(chart.x_max - chart.x_min, 1)
    @margin_left + (step - chart.x_min) / span * (chart.width - @margin_left - @margin_right)
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

  defp mlh(steps, chart) do
    {step, belief} = List.last(steps)

    case belief.mlh do
      nil ->
        nil

      mlh ->
        %{
          graph_id: mlh.graph_id,
          x: rounded(x(step, chart)),
          y: rounded(y(mlh.evidence * 1.0, chart))
        }
    end
  end
end
