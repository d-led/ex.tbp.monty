defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid do
  @moduledoc """
  An image's scales, by octave and by blur.

  Mirrors `tbp/monty/frameworks/models/salience/strategies/vocus2/pyramids.py::Pyramid`,
  a two-dimensional array of images: one row per octave (each half the
  resolution of the one above) and one column per scale (each more blurred than
  the one before). VOCUS2 compares a scale against its neighbours to find
  whatever is unlike its surroundings at that size, and a pyramid is how "that
  size" becomes an index.

  Monty stores the planes in a numpy object array; here an octave is a list of
  planes and the pyramid is a list of octaves, so `planes` read
  `pyramid.planes |> Enum.at(octave) |> Enum.at(scale)`.

  A pyramid with no planes is an error: nothing downstream can tell an empty
  pyramid from an image with nothing in it.
  """

  @enforce_keys [:planes]
  defstruct [:planes]

  @type plane :: [[float()]]
  @type t :: %__MODULE__{planes: [[plane()]]}

  @doc "A pyramid of `octaves`, each a list of `scales` planes of the same shape."
  @spec new([[plane()]]) :: t()
  def new([]), do: raise(ArgumentError, "a pyramid needs at least one octave")

  def new(planes) do
    lengths = planes |> Enum.map(&length/1) |> Enum.uniq()

    case lengths do
      [0] ->
        raise ArgumentError, "a pyramid needs at least one scale per octave"

      [_single] ->
        %__MODULE__{planes: planes}

      _several ->
        raise ArgumentError, "every octave of a pyramid needs as many scales as the first"
    end
  end

  @doc "How many octaves and how many scales: `{octaves, scales}`."
  @spec shape(t()) :: {pos_integer(), pos_integer()}
  def shape(%__MODULE__{planes: planes}), do: {length(planes), planes |> hd() |> length()}

  @doc "How many octaves the pyramid holds."
  @spec n_octaves(t()) :: pos_integer()
  def n_octaves(%__MODULE__{} = pyramid), do: pyramid |> shape() |> elem(0)

  @doc "How many scales each octave holds."
  @spec n_scales(t()) :: pos_integer()
  def n_scales(%__MODULE__{} = pyramid), do: pyramid |> shape() |> elem(1)

  @doc "How many planes the pyramid holds."
  @spec size(t()) :: pos_integer()
  def size(%__MODULE__{} = pyramid), do: pyramid |> n_octaves() |> Kernel.*(n_scales(pyramid))

  @doc "Every plane, octave by octave and scale by scale."
  @spec flat(t()) :: [plane()]
  def flat(%__MODULE__{planes: planes}), do: Enum.flat_map(planes, & &1)

  @doc "The same pyramid with `function` applied to every plane."
  @spec apply(t(), (plane() -> plane())) :: t()
  def apply(%__MODULE__{} = pyramid, function) do
    %__MODULE__{
      pyramid
      | planes: Enum.map(pyramid.planes, fn planes -> Enum.map(planes, function) end)
    }
  end

  @doc "Two pyramids added plane by plane."
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = left, %__MODULE__{} = right) do
    zip_planes(left, right, &add_planes(&1, &2, 1.0))
  end

  @doc "Two pyramids subtracted plane by plane."
  @spec subtract(t(), t()) :: t()
  def subtract(%__MODULE__{} = left, %__MODULE__{} = right) do
    zip_planes(left, right, &add_planes(&1, &2, -1.0))
  end

  # `combine` takes one plane from each pyramid.
  defp zip_planes(%__MODULE__{} = left, %__MODULE__{} = right, combine) do
    if shape(left) != shape(right) do
      raise ArgumentError, "pyramids of different shapes cannot be combined"
    end

    Enum.zip_with([left.planes, right.planes], fn [left_octave, right_octave] ->
      Enum.zip_with([left_octave, right_octave], fn [left_plane, right_plane] ->
        combine.(left_plane, right_plane)
      end)
    end)
    |> new()
  end

  defp add_planes(left, right, sign) do
    Enum.zip_with([left, right], fn [left_row, right_row] ->
      Enum.zip_with([left_row, right_row], fn [left_value, right_value] ->
        left_value + sign * right_value
      end)
    end)
  end
end
