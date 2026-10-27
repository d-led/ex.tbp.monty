defmodule Monty.Frameworks.Utils.SpatialArithmetics.TangentFrame do
  @moduledoc """
  An orthonormal `(u, v, n)` frame riding on a surface.

  Mirrors `tbp/monty/frameworks/utils/spatial_arithmetics.py::TangentFrame`.
  `n` is the surface normal, `u` a tangent direction, `v` completes the
  right-handed set. As the sensor moves over a curved surface, `transport/2`
  turns the frame by exactly the rotation that keeps it in the new tangent
  plane — parallel transport, which is what lets Monty "unroll" a curved
  surface into a flat one.

  A surface normal names a plane but not a basis within it, so the initial `u`
  is picked by crossing an arbitrary axis with the normal. That choice is
  invisible to Monty, which only ever asks for relative directions.
  """

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation

  @some_axis [0.0, 1.0, 0.0]
  @fallback_axis [0.0, 0.0, 1.0]

  @enforce_keys [:normal, :basis_u, :basis_v]
  defstruct [:normal, :basis_u, :basis_v]

  @type vector :: [float()]
  @type t :: %__MODULE__{normal: vector(), basis_u: vector(), basis_v: vector()}

  @doc """
  The frame whose normal is `surface_normal`.

  When `surface_normal` is (anti)parallel to the arbitrary axis, crossing them
  would give zero, so a second axis is used instead.
  """
  @spec new(vector()) :: t()
  def new(surface_normal) do
    normal = SpatialArithmetics.normalize(surface_normal)

    axis =
      if SpatialArithmetics.parallel?(@some_axis, normal), do: @fallback_axis, else: @some_axis

    basis_u =
      normal |> then(&SpatialArithmetics.cross(axis, &1)) |> SpatialArithmetics.normalize()

    %__MODULE__{
      normal: normal,
      basis_u: basis_u,
      basis_v: SpatialArithmetics.normalize(SpatialArithmetics.cross(normal, basis_u))
    }
  end

  @doc "The horizontal tangent direction."
  @spec basis_u(t()) :: vector()
  def basis_u(%__MODULE__{basis_u: basis_u}), do: basis_u

  @doc "The vertical tangent direction."
  @spec basis_v(t()) :: vector()
  def basis_v(%__MODULE__{basis_v: basis_v}), do: basis_v

  @doc "The surface normal this frame rides on."
  @spec normal(t()) :: vector()
  def normal(%__MODULE__{normal: normal}), do: normal

  @doc """
  The frame at `new_normal`, with its basis carried over by the rotation between
  the two normals.

  Normals that already agree need no rotation, and `u` is left alone. Otherwise
  `u` is turned about the axis shared by both tangent planes — the axis
  perpendicular to both normals — so it stays in the plane as the plane tilts.

  The result is re-orthonormalised against `new_normal`: a thousand transports
  over a curved surface would otherwise accumulate enough floating point drift
  for `u` to leave the tangent plane.
  """
  @spec transport(t(), vector()) :: t()
  def transport(%__MODULE__{normal: old_normal, basis_u: basis_u}, new_normal) do
    new_normal = SpatialArithmetics.normalize(new_normal)

    basis_u =
      if SpatialArithmetics.parallel?(old_normal, new_normal) do
        basis_u
      else
        rotate_into_new_plane(basis_u, old_normal, new_normal)
      end

    basis_u =
      SpatialArithmetics.project_onto_tangent_plane(basis_u, new_normal)
      |> SpatialArithmetics.normalize()

    %__MODULE__{
      normal: new_normal,
      basis_u: basis_u,
      basis_v: SpatialArithmetics.cross(new_normal, basis_u)
    }
  end

  defp rotate_into_new_plane(basis_u, old_normal, new_normal) do
    axis = SpatialArithmetics.normalize(SpatialArithmetics.cross(old_normal, new_normal))
    angle = SpatialArithmetics.get_angle(old_normal, new_normal)
    {:ok, rotation} = Rotation.from_axis_angle(axis, angle)
    Rotation.apply(rotation, basis_u)
  end
end
