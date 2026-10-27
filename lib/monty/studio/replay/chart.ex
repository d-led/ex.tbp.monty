defmodule Monty.Studio.Replay.Chart do
  @moduledoc """
  A series drawn as a line, and where the playhead sits in it.

  The geometry is here rather than in HEEx for the same reason the wiring
  diagram's is: "zoomed into steps 3 to 7, the line should enter at the left
  edge" is an assertion, not a matter of taste. Values are scaled to the window
  being looked at, so zooming into a quiet stretch shows the stretch and not a
  flat line at the foot of a chart scaled for the whole run.
  """

  alias Monty.Studio.Replay

  @width 320
  @height 64
  @inset 3

  @enforce_keys [:points, :polyline, :min, :max, :from, :to]
  defstruct [
    :points,
    :polyline,
    :min,
    :max,
    :from,
    :to,
    :playhead,
    width: @width,
    height: @height
  ]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          points: [{float(), float()}],
          polyline: String.t(),
          min: number(),
          max: number(),
          from: number(),
          to: number(),
          playhead: float() | nil
        }

  @doc """
  Draws a series inside a window.

  Options: `:window` (`{from, to}`, required in practice — see `new/2`),
  `:playhead` (the step being replayed). Steps outside the window are not drawn:
  the window is what the reader asked to look at.
  """
  @spec new([Replay.point()], keyword()) :: t()
  def new(points, opts \\ []) do
    {from, to} = window(points, Keyword.get(opts, :window))
    visible = Enum.filter(points, &Replay.inside?({from, to}, &1.step))

    values = Enum.map(visible, & &1.value)
    {min, max} = {Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)}

    scaled =
      Enum.map(visible, fn point -> {x(point.step, from, to), y(point.value, min, max)} end)

    %__MODULE__{
      points: scaled,
      polyline: polyline(scaled),
      min: min,
      max: max,
      from: from,
      to: to,
      playhead: playhead(Keyword.get(opts, :playhead), from, to)
    }
  end

  defp window(_points, {from, to}), do: {from, to}

  defp window(points, _default) do
    case points do
      [] -> {0, 0}
      [first | _rest] -> {first.step, List.last(points).step}
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
