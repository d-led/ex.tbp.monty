defmodule Monty.Simulators.ExMujoco.Orientation do
  @moduledoc """
  `wxyz` quaternions, the way MuJoCo and numpy-quaternion write them.

  An agent's orientation crosses MuJoCo's `qpos` as `w x y z`, and every action
  that turns it — a yaw, a pitch, a head's pitch — composes a rotation onto it.
  This is that arithmetic and nothing else: the operations `priv/monty_py/world.py`
  takes from `numpy-quaternion`, in the same order, so the two worlds move an
  agent identically.

  It is not `Monty.Geometry.Rotation`: that is Monty's own type, `xyzw`, built for
  the model's arithmetic. What crosses into a simulator is MuJoCo's convention,
  and converting at every action would be two chances to get an order wrong.
  """

  @typedoc "An orientation as MuJoCo writes it: `{w, x, y, z}`."
  @type t :: {float(), float(), float(), float()}

  @typedoc "A point or a direction, in metres."
  @type vector :: [float()]

  @typedoc """
  A rotation matrix as its three columns: where the body's own x, y and z axes
  point in the world.
  """
  @type axes ::
          {{float(), float(), float()}, {float(), float(), float()}, {float(), float(), float()}}

  @doc "No rotation."
  @spec identity() :: t()
  def identity, do: {1.0, 0.0, 0.0, 0.0}

  @doc "A rotation of `degrees` about the x axis, anticlockwise."
  @spec about_x(number()) :: t()
  def about_x(degrees) do
    half = degrees * :math.pi() / 360.0
    {:math.cos(half), :math.sin(half), 0.0, 0.0}
  end

  @doc "A rotation of `degrees` about the y axis, anticlockwise."
  @spec about_y(number()) :: t()
  def about_y(degrees) do
    half = degrees * :math.pi() / 360.0
    {:math.cos(half), 0.0, :math.sin(half), 0.0}
  end

  @doc """
  `b` applied after `a` — numpy-quaternion's `a * b`.

  A turn composes on the right, `rotation * about(angle)`, so the new turn is
  taken in the agent's own frame rather than in the world's.
  """
  @spec multiply(t(), t()) :: t()
  def multiply({aw, ax, ay, az}, {bw, bx, by, bz}) do
    {
      aw * bw - ax * bx - ay * by - az * bz,
      aw * bx + ax * bw + ay * bz - az * by,
      aw * by - ax * bz + ay * bw + az * bx,
      aw * bz + ax * by - ay * bx + az * bw
    }
  end

  @doc "The inverse of an orientation, which for unit quaternions is the conjugate."
  @spec invert(t()) :: t()
  def invert({w, x, y, z}), do: {w, -x, -y, -z}

  @doc """
  The rotation matrix, as the three columns numpy-quaternion would give.

  A column is where one of the body's own axes points in the world — which is
  what a step along a local axis moves an agent by.
  """
  @spec axes(t()) :: axes()
  def axes({w, x, y, z}) do
    {
      {1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y + w * z), 2.0 * (x * z - w * y)},
      {2.0 * (x * y - w * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z + w * x)},
      {2.0 * (x * z + w * y), 2.0 * (y * z - w * x), 1.0 - 2.0 * (x * x + y * y)}
    }
  end

  @doc """
  One of the body's own axes, in world coordinates: `0` is x, `1` is y, `2` is z.
  """
  @spec axis(t(), 0 | 1 | 2) :: {float(), float(), float()}
  def axis(orientation, index), do: elem(axes(orientation), index)

  @doc """
  `vector` as seen in this orientation's frame — numpy-quaternion's `rotate_vectors`.
  """
  @spec rotate(t(), vector()) :: vector()
  def rotate(orientation, [x, y, z]) do
    {{xx, xy, xz}, {yx, yy, yz}, {zx, zy, zz}} = axes(orientation)

    [
      xx * x + yx * y + zx * z,
      xy * x + yy * y + zy * z,
      xz * x + yz * y + zz * z
    ]
  end

  @doc """
  The x angle, in radians, of the decomposition `R = Rz(z) · Ry(y) · Rx(x)`.

  This is scipy's `Rotation.as_euler("xyz")`, which is what a sensor head's pitch
  is set from: the head is a hinge, so only the first angle survives.
  """
  @spec euler_x(t()) :: float()
  def euler_x(orientation) do
    {{_, _, _}, {_, _, row_2_1}, {_, _, row_2_2}} = axes(orientation)

    :math.atan2(row_2_1, row_2_2)
  end
end
