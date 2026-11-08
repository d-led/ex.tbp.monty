defmodule Monty.Frameworks.Utils.EdgeDetection.StructureTensor do
  @moduledoc """
  A structure tensor at one point: the 2×2 symmetric matrix `[[xx, xy], [xy, yy]]`.

  Mirrors `tbp/monty/frameworks/utils/edge_detection.py::StructureTensor`.

  Its four numbers are what an edge looks like in a patch of gradients: how
  strongly the brightness changes along x, the same along y, and how much the
  two move together. The eigenvalues of the matrix are the strengths along the
  dominant and the perpendicular direction; an edge is a matrix with one large
  eigenvalue and one small one, and a corner is a matrix with two.
  """

  alias Monty.Math

  @enforce_keys [:xx, :yy, :xy]
  defstruct [:xx, :yy, :xy]

  @type t :: %__MODULE__{xx: float(), yy: float(), xy: float()}

  @doc "The two, from the three numbers."
  @spec new(float(), float(), float()) :: t()
  def new(xx, yy, xy), do: %__MODULE__{xx: xx, yy: yy, xy: xy}

  @doc """
  The smallest and the largest eigenvalue, `{lambda_min, lambda_max}`.

  Monty asks numpy for both; the closed form for a symmetric 2×2 is the same
  answer and says what it is: their sum is the trace and their product the
  determinant, so they are `mean ± sqrt(mean² - determinant)` with
  `mean = (xx + yy) / 2`.
  """
  @spec eigenvalues(t()) :: {float(), float()}
  def eigenvalues(%__MODULE__{xx: xx, yy: yy, xy: xy}) do
    mean = (xx + yy) / 2
    half_difference = (xx - yy) / 2
    root = :math.sqrt(half_difference * half_difference + xy * xy)

    {mean - root, mean + root}
  end

  @doc """
  The gradient direction in radians, normal to the dominant edge.

  In `(-π/2, π/2]`: an orientation, not a heading, because the tensor cannot
  tell one side of an edge from the other.
  """
  @spec gradient_theta(t()) :: float()
  def gradient_theta(%__MODULE__{xx: xx, yy: yy, xy: xy}) do
    0.5 * :math.atan2(2.0 * xy, xx - yy)
  end

  @doc """
  How strong the strongest edge in the tensor is: the root of the larger
  eigenvalue, floored at zero because a numerically tiny negative eigenvalue is
  noise, not a negative edge.
  """
  @spec edge_strength(t()) :: float()
  def edge_strength(%__MODULE__{} = tensor) do
    {_lambda_min, lambda_max} = eigenvalues(tensor)
    :math.sqrt(max(lambda_max, 0.0))
  end

  @doc """
  How *oriented* the tensor is, in `[0, 1]`: 1 is a single clean edge, 0 is a
  patch with no direction at all.

  `(lambda_max - lambda_min) / (lambda_max + lambda_min)`. Two eigenvalues a
  hair apart are a round patch, not an edge, and Monty calls that zero rather
  than letting rounding turn noise into confidence.
  """
  @spec coherence(t()) :: float()
  def coherence(%__MODULE__{} = tensor) do
    {lambda_min, lambda_max} = eigenvalues(tensor)
    difference = lambda_max - lambda_min

    if difference < Math.default_tolerance() do
      0.0
    else
      (difference / (lambda_max + lambda_min))
      |> max(0.0)
      |> min(1.0)
    end
  end

  @doc "The edge direction in `[0, π]`: perpendicular to the gradient."
  @spec edge_angle(t()) :: float()
  def edge_angle(%__MODULE__{} = tensor) do
    tensor |> gradient_theta() |> Monty.Frameworks.Utils.EdgeDetection.gradient_to_tangent_angle()
  end
end
