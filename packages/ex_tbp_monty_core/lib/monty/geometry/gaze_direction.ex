defmodule Monty.Geometry.GazeDirection do
  @moduledoc """
  A gaze goal expressed as a matrix whose first row points opposite the surface
  normal.

  Mirrors `tbp/monty/geometry.py::GazeDirection`. Like the Python type it cannot
  be rotated: `Monty.Cmp.Message.transform_morphological_features/3` refuses to
  transform it.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: [[float() | nil]]}

  @doc "The gaze direction: the negated surface normal."
  @spec direction(t()) :: [float()]
  def direction(%__MODULE__{value: [direction | _rest]}), do: direction
end
