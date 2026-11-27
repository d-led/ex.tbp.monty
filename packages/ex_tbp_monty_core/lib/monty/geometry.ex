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

  Written out rather than built from `transpose/1` and a map of `dot/2` calls:
  this is nine multiplications and six additions, and the general shape spent
  six closures and three intermediate lists on them. In a step it is called once
  per hypothesis to rotate a frame, so it is one of the few places where the
  arithmetic has to be the whole function.
  """
  @spec mul([[number()]], [[number()]]) :: [[float()]]
  def mul(
        [[a1, a2, a3], [b1, b2, b3], [c1, c2, c3]],
        [[x1, x2, x3], [y1, y2, y3], [z1, z2, z3]]
      ) do
    [
      [a1 * x1 + a2 * y1 + a3 * z1, a1 * x2 + a2 * y2 + a3 * z2, a1 * x3 + a2 * y3 + a3 * z3],
      [b1 * x1 + b2 * y1 + b3 * z1, b1 * x2 + b2 * y2 + b3 * z2, b1 * x3 + b2 * y3 + b3 * z3],
      [c1 * x1 + c2 * y1 + c3 * z1, c1 * x2 + c2 * y2 + c3 * z2, c1 * x3 + c2 * y3 + c3 * z3]
    ]
  end

  @doc "Transposes a 3×3 matrix."
  @spec transpose([[number()]]) :: [[number()]]
  def transpose([[a, b, c], [d, e, f], [g, h, i]]) do
    [[a, d, g], [b, e, h], [c, f, i]]
  end

  @doc "Dot product of two 3-vectors."
  @spec dot([number()], [number()]) :: number()
  def dot([a1, a2, a3], [b1, b2, b3]), do: a1 * b1 + a2 * b2 + a3 * b3

  @doc """
  Multiplies a 3×3 matrix by a 3-vector.

  Three dot products, written as three dot products — the map and its closure
  were most of what this cost.
  """
  @spec apply([[number()]], [number()]) :: [number()]
  def apply([[a1, a2, a3], [b1, b2, b3], [c1, c2, c3]], [x, y, z]) do
    [a1 * x + a2 * y + a3 * z, b1 * x + b2 * y + b3 * z, c1 * x + c2 * y + c3 * z]
  end

  @doc "Adds two 3-vectors."
  @spec add([number()], [number()]) :: [number()]
  def add([a1, a2, a3], [b1, b2, b3]), do: [a1 + b1, a2 + b2, a3 + b3]

  @doc "Subtracts two 3-vectors."
  @spec subtract([number()], [number()]) :: [number()]
  def subtract([a1, a2, a3], [b1, b2, b3]), do: [a1 - b1, a2 - b2, a3 - b3]

  @doc """
  A quaternion in scalar-last (xyzw) order, from scalar-first (wxyz).

  Monty's `to_scalar_last`, which is `np.asarray(wxyz)[..., [1, 2, 3, 0]]`: an
  index permutation, and the order scipy's `Rotation` takes. It works on one
  quaternion and on a list of them, as Monty's does, because Monty's callers hand
  a batch over.

  Monty keeps these two because its `Rotation` is a wrapper around scipy's and
  the order changes at that boundary; the port's `Rotation` holds `wxyz` itself,
  so what is left of them here is the boundary — a quaternion written for
  something outside this port.
  """
  @spec to_scalar_last([number()] | [[number()]]) :: [number()] | [[number()]]
  def to_scalar_last([first | _rest] = wxyz) when is_list(first),
    do: Enum.map(wxyz, &to_scalar_last/1)

  def to_scalar_last([w, x, y, z]), do: [x, y, z, w]

  @doc """
  A quaternion in scalar-first (wxyz) order, from scalar-last (xyzw).

  Monty's `to_scalar_first`, the inverse permutation of `to_scalar_last/1`, and
  read on one quaternion or on a list of them.
  """
  @spec to_scalar_first([number()] | [[number()]]) :: [number()] | [[number()]]
  def to_scalar_first([first | _rest] = xyzw) when is_list(first),
    do: Enum.map(xyzw, &to_scalar_first/1)

  def to_scalar_first([x, y, z, w]), do: [w, x, y, z]

  @doc """
  Whether two rotations are the same within `tol` radians — Monty's
  `scipy_rotations_approx_equal`.

  scipy asks whether the *angle* of `a · b⁻¹` is inside the tolerance, and so
  does this, from the same quaternion: the angle is `2·atan2(|vector|, |scalar|)`.
  `atan2` rather than `acos` because a pair one tolerance apart has a cosine of
  `1 − tol²/8`, and `acos` there is only accurate to about `1e-10` — a thousandth
  of the tolerance the caller is asking about.

  `|scalar|`, because a quaternion and its negative are one rotation.
  """
  @spec rotations_approx_equal?(Monty.Geometry.Rotation.t(), Monty.Geometry.Rotation.t(), float()) ::
          boolean()
  def rotations_approx_equal?(
        %Monty.Geometry.Rotation{} = left,
        %Monty.Geometry.Rotation{} = right,
        tol \\ 1.0e-6
      ) do
    {w, x, y, z} =
      left
      |> Monty.Geometry.Rotation.multiply(Monty.Geometry.Rotation.invert(right))
      |> Monty.Geometry.Rotation.to_quaternion()

    2.0 * :math.atan2(:math.sqrt(x * x + y * y + z * z), abs(w)) <= tol
  end
end
