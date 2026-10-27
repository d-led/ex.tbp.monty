defmodule Monty.Geometry.Rotation do
  @moduledoc """
  A rotation, as the quaternion `wxyz` Monty passes around.

  Mirrors `tbp/monty/geometry.py::Rotation`, which wraps `scipy`'s
  `Rotation` — so what is mirrored here is the behaviour Monty relies on, not
  scipy's surface: rotation vectors, rotation matrices, Euler angles and
  quaternions each convert to the others, a rotation can be inverted, and it can
  be applied to a vector or a matrix of them.

  Two conventions are kept exactly as scipy has them, because getting either
  wrong rotates a reference frame without any number looking wrong:

    * a quaternion is `{w, x, y, z}` here (Monty's `QuaternionWXYZ`), while the
      `[x, y, z, w]` order is what scipy returns from `as_quat()` — the
      conversion functions say which is which;
    * `from_euler("xyz", angles, degrees: true)` is scipy's *extrinsic* order:
      rotate about x, then about the (fixed) y, then about the (fixed) z.
  """

  alias Monty.Math

  @enforce_keys [:wxyz]
  defstruct [:wxyz]

  @type vector :: [float()]
  @type matrix :: [[float()]]
  @type t :: %__MODULE__{wxyz: {float(), float(), float(), float()}}

  @doc "The rotation of no angle, `w = 1`."
  @spec identity() :: t()
  def identity, do: %__MODULE__{wxyz: Math.identity_quaternion()}

  @doc """
  The rotation of `angle` radians about `axis`.

  A zero axis has no rotation to describe, and `{:error, :zero_axis}` is the
  honest answer — scipy normalises the axis and produces NaN, which is worse.
  """
  @spec from_axis_angle(vector(), float()) :: {:ok, t()} | {:error, :zero_axis}
  def from_axis_angle(axis, angle) do
    case unit(axis) do
      :zero ->
        {:error, :zero_axis}

      [x, y, z] ->
        half = angle / 2
        sin_half = :math.sin(half)
        {:ok, %__MODULE__{wxyz: {:math.cos(half), x * sin_half, y * sin_half, z * sin_half}}}
    end
  end

  @doc "The rotation a quaternion `{w, x, y, z}` describes, normalised."
  @spec from_quaternion({number(), number(), number(), number()}) :: {:ok, t()} | {:error, term()}
  def from_quaternion({_w, _x, _y, _z} = quaternion) do
    case unit(Tuple.to_list(quaternion)) do
      :zero -> {:error, :zero_quaternion}
      [w, x, y, z] -> {:ok, %__MODULE__{wxyz: {w, x, y, z}}}
    end
  end

  @doc "The rotation a 3×3 rotation matrix describes."
  @spec from_matrix(matrix()) :: {:ok, t()} | {:error, :not_a_rotation}
  def from_matrix([[m00, m01, m02], [m10, m11, m12], [m20, m21, m22]]) do
    trace = m00 + m11 + m22

    quaternion =
      cond do
        trace > 0 ->
          s = :math.sqrt(trace + 1.0) * 2
          {0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s}

        m00 > m11 and m00 > m22 ->
          s = :math.sqrt(1.0 + m00 - m11 - m22) * 2
          {(m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s}

        m11 > m22 ->
          s = :math.sqrt(1.0 + m11 - m00 - m22) * 2
          {(m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s}

        true ->
          s = :math.sqrt(1.0 + m22 - m00 - m11) * 2
          {(m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s}
      end

    # A matrix that is not a rotation (a mirror, say) still has a quaternion of
    # the right shape, and normalising it gives the closest rotation — which is
    # what scipy does, and what lets the alignment error notice the mirror.
    case from_quaternion(quaternion) do
      {:ok, rotation} -> {:ok, rotation}
      {:error, _reason} -> {:error, :not_a_rotation}
    end
  end

  @doc """
  The rotation of three Euler angles in degrees, applied about the fixed x, then
  y, then z axes (scipy's `from_euler("xyz", angles, degrees=True)`).

  Extrinsic order means the composed rotation is `Rz · Ry · Rx`: `x` turns
  first, in the frame the axes were given in.
  """
  @spec from_euler_degrees(vector()) :: {:ok, t()}
  def from_euler_degrees([rx, ry, rz]) do
    {:ok,
     quaternion_z(deg(rz))
     |> multiply(quaternion_y(deg(ry)))
     |> multiply(quaternion_x(deg(rx)))}
  end

  @doc """
  The three Euler angles in degrees about the fixed x, y and z axes.

  The angles are rounded to `decimal_places`, because Monty compares them as
  labels (`np.round(pose.as_euler(...), 3) % 360`) and an unrounded 359.9999
  would read as a different pose from 0.0.
  """
  @spec to_euler_degrees(t(), non_neg_integer()) :: vector()
  def to_euler_degrees(%__MODULE__{} = rotation, decimal_places \\ 3) do
    [[m00, m01, m02], [m10, m11, m12], [m20, m21, m22]] = to_matrix(rotation)
    sin_ry = -m20

    angles =
      if abs(sin_ry) < 1.0 - 1.0e-9 do
        [
          rad_to_deg(:math.atan2(m21, m22)),
          rad_to_deg(:math.asin(sin_ry)),
          rad_to_deg(:math.atan2(m10, m00))
        ]
      else
        # Gimbal lock: the x and z axes have collapsed onto one another, so the
        # split between them is arbitrary. scipy puts it all in x.
        [rad_to_deg(:math.atan2(-m12, m11)), rad_to_deg(:math.asin(sin_ry)), 0.0]
      end

    _ = {m01, m02, m12}
    Enum.map(angles, &round_to(&1, decimal_places))
  end

  @doc """
  The angle this rotation turns through, in radians, in `[0, π]`.

  This is what Monty compares against `pose_similarity_threshold`: two rotations
  are the same pose when rotating from one to the other turns by less than the
  threshold.
  """
  @spec magnitude(t()) :: float()
  def magnitude(%__MODULE__{wxyz: {w, _x, _y, _z}}) do
    half_angle = :math.acos(min(abs(w), 1.0))
    2 * half_angle
  end

  @doc "The quaternion `{w, x, y, z}`."
  @spec to_quaternion(t()) :: {float(), float(), float(), float()}
  def to_quaternion(%__MODULE__{wxyz: wxyz}), do: wxyz

  @doc "The quaternion `[x, y, z, w]`, which is the order scipy returns."
  @spec to_xyzw(t()) :: [float()]
  def to_xyzw(%__MODULE__{wxyz: {w, x, y, z}}), do: [x, y, z, w]

  @doc "The 3×3 rotation matrix this rotation applies."
  @spec to_matrix(t()) :: matrix()
  def to_matrix(%__MODULE__{wxyz: {w, x, y, z}}) do
    xx = x * x
    yy = y * y
    zz = z * z
    xy = x * y
    xz = x * z
    yz = y * z
    wx = w * x
    wy = w * y
    wz = w * z

    [
      [1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy)],
      [2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx)],
      [2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy)]
    ]
  end

  @doc "The rotation that undoes this one."
  @spec invert(t()) :: t()
  def invert(%__MODULE__{wxyz: {w, x, y, z}}), do: %__MODULE__{wxyz: {w, -x, -y, -z}}

  @doc "This rotation after `other`: applying the result is applying `other` then this."
  @spec multiply(t(), t()) :: t()
  def multiply(%__MODULE__{wxyz: {w1, x1, y1, z1}}, %__MODULE__{wxyz: {w2, x2, y2, z2}}) do
    quat(
      w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
      w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
      w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
      w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2
    )
  end

  @doc "Applies this rotation to a 3-vector, or to each row of a list of them."
  @spec apply(t(), vector() | [vector()]) :: vector() | [vector()]
  def apply(%__MODULE__{} = rotation, [a, b, c]) when is_number(a) do
    matrix = to_matrix(rotation)
    Enum.map(matrix, &dot(&1, [a, b, c]))
  end

  def apply(%__MODULE__{} = rotation, vectors) when is_list(vectors) do
    matrices = to_matrix(rotation)
    Enum.map(vectors, fn vector -> Enum.map(matrices, &dot(&1, vector)) end)
  end

  defp dot([a1, a2, a3], [b1, b2, b3]), do: a1 * b1 + a2 * b2 + a3 * b3

  defp quat(w, x, y, z), do: %__MODULE__{wxyz: {w * 1.0, x * 1.0, y * 1.0, z * 1.0}}

  defp quaternion_x(angle), do: axis_quaternion(:x, angle)
  defp quaternion_y(angle), do: axis_quaternion(:y, angle)
  defp quaternion_z(angle), do: axis_quaternion(:z, angle)

  defp axis_quaternion(axis, angle) do
    {:ok, rotation} = from_axis_angle(axis_vector(axis), angle)
    rotation
  end

  defp axis_vector(:x), do: [1.0, 0.0, 0.0]
  defp axis_vector(:y), do: [0.0, 1.0, 0.0]
  defp axis_vector(:z), do: [0.0, 0.0, 1.0]

  defp deg(radians), do: radians * :math.pi() / 180

  defp rad_to_deg(radians), do: radians * 180 / :math.pi()

  defp round_to(value, decimal_places), do: Float.round(value, decimal_places)

  defp unit(vector) do
    norm = :math.sqrt(Enum.sum(Enum.map(vector, &(&1 * &1))))

    if norm < Monty.Math.default_tolerance(),
      do: :zero,
      else: Enum.map(vector, &(&1 / norm))
  end
end
