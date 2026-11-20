defmodule Monty.Frameworks.Environments.TwoDData do
  @moduledoc """
  The helper functions of `tbp/monty/frameworks/environments/two_d_data.py`.

  Monty keeps the classes of that file in modules of their own here, so what is
  left in the file module is what the file keeps outside a class: the three
  functions its Omniglot tutorial borrowed from the dataset's own `demo.py` — read
  a drawing, read the pen path that drew it, and put that path in the image's
  coordinates.

  A drawing is one bit a pixel: ink or no ink. `load_img/1` answers booleans,
  `true` where the paper is, which is Monty's `np.array(plt.imread(fn), dtype=bool)`
  — a PNG's white pixel is the nonzero one, so `true` is the background and the
  stroke is `false`.

  A pen path is the order the character was drawn in: the dataset's `strokes/`
  text files hold one point a line, `START` before a stroke and `BREAK` after it,
  each point an `x,y,time` triple — the position in the dataset's own
  coordinates, where a stroke's `y` grows upwards. `space_motor_to_img/1` flips
  that axis, because an image's rows grow downwards.
  """

  alias ExTbpMonty.Core.Png

  @typedoc "One drawing as rows of pixels: `true` is paper, `false` is ink."
  @type drawing :: [[boolean()]]

  @typedoc "One pen position, in the dataset's `x, y, time` coordinates."
  @type point :: [float()]

  @typedoc "A stroke: the points drawn without lifting the pen."
  @type stroke :: [point()]

  @doc """
  A drawing, as the pixels the file holds.

  Monty reads it with `matplotlib.pyplot.imread` and keeps the nonzero pixels, so
  a drawing is a picture of two colours and nothing more. Anything this port
  cannot read as a picture is refused rather than read as a blank page.
  """
  # `path` is one file under the data directory the world was started on, not
  # anything a browser supplies.
  # sobelow_skip ["Traversal.FileModule"]
  @spec load_img(Path.t()) :: drawing()
  def load_img(path) do
    case path |> File.read!() |> Png.decode() do
      {:ok, image} ->
        pixels_of(image)

      {:error, reason} ->
        raise ArgumentError, "#{path} is not a drawing this port can read: #{reason}"
    end
  end

  defp pixels_of(%{width: width, height: height, channels: 1, pixels: pixels}) do
    for row <- 0..(height - 1) do
      for column <- 0..(width - 1), do: :binary.at(pixels, row * width + column) != 0
    end
  end

  @doc """
  The strokes that drew a character, in the order they were drawn.

  `START` opens a stroke and `BREAK` closes it; a line between them is a point. A
  stroke the file never closed is not a stroke Monty keeps, so it is dropped here
  too.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec load_motor(Path.t()) :: [stroke()]
  def load_motor(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({[], []}, &stroke/2)
    |> then(fn {strokes, _unclosed} -> Enum.reverse(strokes) end)
  end

  defp stroke("START", {strokes, _stroke}), do: {strokes, []}

  defp stroke("BREAK", {strokes, stroke}), do: {[Enum.reverse(stroke) | strokes], []}

  defp stroke("", state), do: state

  defp stroke(line, {strokes, stroke}), do: {strokes, [point(line) | stroke]}

  defp point(line) do
    line
    |> String.split(",")
    |> Enum.map(&number/1)
  end

  defp number(field) do
    case Float.parse(String.trim(field)) do
      {value, _rest} -> value
      :error -> raise ArgumentError, "a pen path's #{inspect(field)} is not a number"
    end
  end

  @doc """
  The same points in the image's coordinates: the second axis flipped.

  The dataset draws with `y` upwards and an image has its first row at the top, so
  Monty negates `y` and leaves `x` where it is — `pt[:, 1] = -pt[:, 1]`.
  """
  @spec space_motor_to_img([point()]) :: [point()]
  def space_motor_to_img(points) do
    Enum.map(points, fn [x, y | rest] -> [x, -y | rest] end)
  end
end
