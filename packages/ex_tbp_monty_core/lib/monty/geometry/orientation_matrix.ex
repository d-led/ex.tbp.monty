defmodule Monty.Geometry.OrientationMatrix do
  @moduledoc """
  A rotation matrix representing object orientation.

  Mirrors `tbp/monty/geometry.py::OrientationMatrix`. The rows are the object's
  `x`, `y` and `z` axes.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: [[float()]]}
end
