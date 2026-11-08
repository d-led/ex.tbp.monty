defmodule Monty.Geometry do
  @moduledoc """
  Small 3×3 matrix arithmetic and pose helpers.

  Mirrors `tbp/monty/geometry.py` where it matters for the messaging layer: the
  pose-vector types live in `Monty.Geometry.*` and matrix products used to
  transform them live here. Anything heavier (quaternions, alignment, batch
  rotation) arrives with the numeric core and is tested against Monty's own
  fixtures.
  """

  @doc "The 3×3 identity matrix."
  @spec identity() :: [[float()]]
  def identity, do: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]

  @doc """
  Multiplies two 3×3 matrices.

  `left * right`, row-major, the way `numpy.dot` reads.
  """
  @spec mul([[number()]], [[number()]]) :: [[float()]]
  def mul(left, right) do
    right_columns = transpose(right)

    Enum.map(left, fn row ->
      Enum.map(right_columns, fn column -> dot(row, column) end)
    end)
  end

  @doc "Transposes a 3×3 matrix."
  @spec transpose([[number()]]) :: [[number()]]
  def transpose([[a, b, c], [d, e, f], [g, h, i]]) do
    [[a, d, g], [b, e, h], [c, f, i]]
  end

  @doc "Dot product of two 3-vectors."
  @spec dot([number()], [number()]) :: number()
  def dot([a1, a2, a3], [b1, b2, b3]), do: a1 * b1 + a2 * b2 + a3 * b3

  @doc "Multiplies a 3×3 matrix by a 3-vector."
  @spec apply([[number()]], [number()]) :: [number()]
  def apply(matrix, vector), do: Enum.map(matrix, &dot(&1, vector))

  @doc "Adds two 3-vectors."
  @spec add([number()], [number()]) :: [number()]
  def add([a1, a2, a3], [b1, b2, b3]), do: [a1 + b1, a2 + b2, a3 + b3]

  @doc "Subtracts two 3-vectors."
  @spec subtract([number()], [number()]) :: [number()]
  def subtract([a1, a2, a3], [b1, b2, b3]), do: [a1 - b1, a2 - b2, a3 - b3]
end
