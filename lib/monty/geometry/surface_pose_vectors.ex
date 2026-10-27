defmodule Monty.Geometry.SurfacePoseVectors do
  @moduledoc """
  Surface normal and the two principal curvature directions.

  Mirrors `tbp/monty/geometry.py::SurfacePoseVectors`.

  `value` is a 3×3 matrix in row-major order, in `[z (surface normal),
  x (principal curvature 1), y (principal curvature 2)]` order. It is meant to
  be a proper rotation (determinant 1, orthonormal rows); like the Python class
  this module does not validate that, because Monty itself constructs
  degenerate instances when the curvature estimate is flat.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type vector :: [float()]
  @type t :: %__MODULE__{value: [vector()]}

  @doc "Builds pose vectors from three row vectors."
  @spec new(vector(), vector(), vector()) :: t()
  def new(surface_normal, principal_curvature_1, principal_curvature_2) do
    %__MODULE__{
      value: [surface_normal, principal_curvature_1, principal_curvature_2]
    }
  end

  @spec surface_normal(t()) :: vector()
  def surface_normal(%__MODULE__{value: [normal, _, _]}), do: normal

  @spec principal_curvature_1(t()) :: vector()
  def principal_curvature_1(%__MODULE__{value: [_, pc1, _]}), do: pc1

  @spec principal_curvature_2(t()) :: vector()
  def principal_curvature_2(%__MODULE__{value: [_, _, pc2]}), do: pc2
end
