defmodule Monty.Test.EdgeDetectorFixture do
  @moduledoc """
  The patches and cameras Monty's `edge_detection_test.py` builds inline.

  A patch is rows of `[r, g, b, a]`; the cases only care about the first three,
  which is what a detector reads. The two edge patches are the ones the Python
  fixtures cut: a half-plane through the centre at a given angle, and one at the
  right-hand border with nothing in the middle.
  """

  @doc """
  A patch of a single shade — nothing for an edge detector to find.

  Monty's `UNIFORM_PATCH`: mid grey everywhere.
  """
  @spec uniform(pos_integer()) :: [[[0..255]]]
  def uniform(size), do: List.duplicate(List.duplicate([128, 128, 128, 255], size), size)

  @doc """
  A patch cut in two by a half-plane through its centre, at `angle` radians.

  Monty's `make_angled_edge_patch`: the two halves are black and white, and the
  line runs through the centre whichever way it is turned — so the centre check
  has nothing to object to and the angle is the whole of the answer.
  """
  @spec angled_edge(float(), pos_integer()) :: [[[0..255]]]
  def angled_edge(angle, size) do
    centre = (size - 1) / 2

    for row <- 0..(size - 1)//1 do
      for column <- 0..(size - 1)//1 do
        distance =
          (column - centre) * -:math.sin(angle) + (row - centre) * :math.cos(angle)

        if distance >= 0, do: [255, 255, 255, 255], else: [0, 0, 0, 255]
      end
    end
  end

  @doc """
  A patch whose only edge is four pixels from the right-hand border.

  Monty's off-centre case: the shade changes where the weighted neighbourhood
  has almost nothing to see, so the tensors that do exist sit at the rim.
  """
  @spec edge_at_right_border(pos_integer()) :: [[[0..255]]]
  def edge_at_right_border(size) do
    for _row <- 0..(size - 1)//1 do
      for column <- 0..(size - 1)//1 do
        if column >= size - 4, do: [255, 255, 255, 255], else: [0, 0, 0, 255]
      end
    end
  end

  @doc "A depth patch of one distance everywhere: no crease anywhere in it."
  @spec flat_depth(pos_integer()) :: [[float()]]
  def flat_depth(size), do: List.duplicate(List.duplicate(1.0, size), size)

  @doc """
  One of Monty's three camera-to-world transforms.

    * `:identity` — the camera looks along `+z`, `x` right and `y` down.
    * `:x_to_y_camera` — the camera's `x` is the world's `y`, so the surface it
      faces is `x`.
    * `:y_to_z_camera` — the camera's `y` is the world's `-z`, so the surface it
      faces is `y`.
  """
  @spec camera(:identity | :x_to_y_camera | :y_to_z_camera) :: [[float()]]
  def camera(:identity) do
    [
      [1.0, 0.0, 0.0, 0.0],
      [0.0, 1.0, 0.0, 0.0],
      [0.0, 0.0, 1.0, 0.0],
      [0.0, 0.0, 0.0, 1.0]
    ]
  end

  def camera(:x_to_y_camera) do
    [
      [0.0, -1.0, 0.0, 0.0],
      [1.0, 0.0, 0.0, 0.0],
      [0.0, 0.0, 1.0, 0.0],
      [0.0, 0.0, 0.0, 1.0]
    ]
  end

  def camera(:y_to_z_camera) do
    [
      [1.0, 0.0, 0.0, 0.0],
      [0.0, 0.0, -1.0, 0.0],
      [0.0, 1.0, 0.0, 0.0],
      [0.0, 0.0, 0.0, 1.0]
    ]
  end

  @doc """
  Monty's `compute_expected_pose_2d`: the answer, worked out the other way round.

  The production code combines `cos(angle)` of the image's `x` with `sin(angle)`
  of `-y`; this combines `cos(angle)` of `x` with `-sin(angle)` of `y`, which is
  the same thing written as Monty's test writes it. Two spellings of one formula
  is what makes the transported-frame case an independent check.
  """
  @spec expected_pose_2d(
          float(),
          [[float()]],
          [float()],
          Monty.Frameworks.Utils.SpatialArithmetics.TangentFrame.t()
        ) ::
          Monty.Geometry.SurfacePoseVectors.t()
  def expected_pose_2d(angle, cam_to_world, surface_normal, frame) do
    rotation = cam_to_world |> Enum.take(3) |> Enum.map(&Enum.take(&1, 3))
    image_x_world = rotate(rotation, [1.0, 0.0, 0.0])
    image_y_world = rotate(rotation, [0.0, 1.0, 0.0])

    edge_world =
      image_x_world
      |> Enum.zip(image_y_world)
      |> Enum.map(fn {x, y} -> :math.cos(angle) * x - :math.sin(angle) * y end)

    tangent =
      Monty.Frameworks.Utils.SpatialArithmetics.project_onto_tangent_plane(
        edge_world,
        surface_normal
      )

    tangent =
      if magnitude(tangent) < Monty.Math.default_tolerance() do
        frame.basis_u
      else
        Monty.Frameworks.Utils.SpatialArithmetics.normalize(tangent)
      end

    in_plane =
      Monty.Frameworks.Utils.SpatialArithmetics.normalize([
        dot(tangent, frame.basis_u),
        dot(tangent, frame.basis_v),
        0.0
      ])

    [u, v, _zero] = in_plane

    Monty.Geometry.SurfacePoseVectors.new([0.0, 0.0, 1.0], in_plane, [-v, u, 0.0])
  end

  defp rotate(matrix, vector), do: Enum.map(matrix, &dot(&1, vector))

  defp dot(first, second) do
    first |> Enum.zip(second) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
  end

  defp magnitude(vector), do: vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
end
