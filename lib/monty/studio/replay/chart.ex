defmodule Monty.Studio.Replay.Chart do
  @moduledoc """
  Series drawn as lines over one pair of axes, and where the playhead sits.

  The geometry is here rather than in HEEx for the same reason the wiring
  diagram's is: "zoomed into steps 3 to 7, the line should enter at the left
  edge" is an assertion, not a matter of taste. Values are scaled to the window
  being looked at, so zooming into a quiet stretch shows the stretch and not a
  flat line at the foot of a chart scaled for the whole run.

  One chart holds many lines because that is how an episode is read: every object
  a learning module still had a graph for, on the same axis. The moment one line
  climbs away from the rest is the recognition, and it is visible as a shape
  rather than as a table to compare.
  """

  alias Monty.Studio.Replay

  @width 320
  @height 64
  @inset 3

  @enforce_keys [:lines, :min, :max, :from, :to]
  defstruct [
    :min,
    :max,
    :from,
    :to,
    :playhead,
    lines: [],
    hover: [],
    width: @width,
    height: @height
  ]

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
          polyline: String.t()
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
          min: number(),
          max: number(),
          from: number(),
          to: number(),
          playhead: float() | nil,
          hover: [sample()]
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

    values = Enum.flat_map(visible, fn drawn -> Enum.map(drawn.points, & &1.value) end)
    {min, max} = {Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)}

    {lines, samples} =
      visible
      |> Enum.with_index()
      |> Enum.map(&line(&1, {from, to}, {min, max}))
      |> Enum.unzip()

    %__MODULE__{
      lines: lines,
      min: min,
      max: max,
      from: from,
      to: to,
      hover: List.flatten(samples),
      playhead: playhead(Keyword.get(opts, :playhead), from, to)
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
      polyline: polyline(points)
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

  defp x(_step, from, to) when to == from, do: @width / 2
  defp x(step, from, to), do: (step - from) / (to - from) * @width

  defp y(_value, min, max) when max == min, do: @height / 2

  defp y(value, min, max) do
    @height - @inset - (value - min) / (max - min) * (@height - 2 * @inset)
  end

  defp playhead(nil, _from, _to), do: nil
  defp playhead(step, from, to), do: x(step, from, to)

  defp polyline([]), do: ""

  defp polyline(points),
    do: points |> Enum.map_join(" ", fn {x, y} -> "#{round(x)},#{round(y)}" end)
end
