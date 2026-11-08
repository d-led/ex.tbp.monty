defmodule Monty.Frameworks.Utils.EdgeDetection do
  @moduledoc """
  Finding the edge in a patch of pixels, and saying which way it points.

  Mirrors `tbp/monty/frameworks/utils/edge_detection.py`. The two functions here
  are the ones Monty keeps at module level; the detector itself is
  `...EdgeDetection.EdgeDetector`, what it returns is
  `...EdgeDetection.EdgeFeatures`, and the matrix it aggregates is
  `...EdgeDetection.StructureTensor`.

  ## What an edge is here

  A structure tensor over a patch of Sobel gradients, weighted towards the
  centre of the patch and towards pixels where the gradient is strong. Two
  numbers come out of it: how strong the edge is, and how *coherent* — one clean
  direction against a wash of them. An edge is reported when both clear their
  thresholds, which is why a uniform patch reports nothing at all rather than
  reporting a weak edge in an arbitrary direction.

  ## The 2-D frame an edge implies

  A surface agent moves on a curved surface, so a direction in the image is not
  a direction on the object. `angle_to_pose_2d/4` projects the image direction
  onto the local tangent plane and expresses it in that plane's frame, which is
  the basis the 2-D model is built in. `TangentFrame` carries that basis, and it
  is *transported* from step to step rather than recomputed, because a basis
  that jumped at every step would make the model's coordinates jump with it.

  ## What this port supplies that Monty borrows

  Monty reads pixels with OpenCV: `cvtColor`, `Sobel`, `GaussianBlur`. This port
  has no OpenCV, so `...EdgeDetection.ImageOps` writes those three — the same
  filters, over the same reflection at the patch border, which is what makes the
  same patch give the same edge.
  """

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Frameworks.Utils.SpatialArithmetics.TangentFrame
  alias Monty.Geometry.SurfacePoseVectors
  alias Monty.Math

  # The frame a patch that says nothing about edges is given: the patch plane is
  # `z`, the first direction across it is `x`, the second `y`.
  @default_surface_pose_vectors_2d %SurfacePoseVectors{
    value: [[0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]
  }

  @doc "The identity 2-D frame: normal `z`, tangent `x`, and `y` across it."
  @spec default_surface_pose_vectors_2d() :: SurfacePoseVectors.t()
  def default_surface_pose_vectors_2d, do: @default_surface_pose_vectors_2d

  @doc """
  Turns a gradient direction into an edge direction, wrapped to `[0, 2π)`.

  An edge runs *across* its gradient, so a quarter turn. The wrap is what makes
  the answer an orientation rather than a heading: a gradient pointing slightly
  below the x-axis gives an edge just below 2π, not a negative angle.
  """
  @spec gradient_to_tangent_angle(float()) :: float()
  def gradient_to_tangent_angle(gradient_angle) do
    tangent_angle = gradient_angle + :math.pi() / 2
    tangent_angle - :math.floor(tangent_angle / (2 * :math.pi())) * (2 * :math.pi())
  end

  @doc """
  The 2-D pose an image-space edge angle implies, in the local tangent frame.

  The image's `x` axis and its `y` axis (pointing *down* the image) are turned
  into world directions by the camera's rotation, combined at `angle`, and
  projected onto the tangent plane at `surface_normal`. What comes back is the
  edge's direction in that plane as `[normal, edge_tangent, edge_perpendicular]`
  — the normal always `[0, 0, 1]`, because this is the model's own 2-D frame,
  not a direction in space.

  A world direction that vanishes when projected (an edge seen edge-on) is not a
  direction at all, so the frame's own first basis vector stands in.
  """
  @spec angle_to_pose_2d(float(), [[float()]], [float()], TangentFrame.t()) ::
          SurfacePoseVectors.t()
  def angle_to_pose_2d(angle, cam_to_world, surface_normal, tangent_frame) do
    rotation = cam_to_world |> Enum.take(3) |> Enum.map(&Enum.take(&1, 3))
    image_x_world = rotate(rotation, [1.0, 0.0, 0.0])
    image_y_world = rotate(rotation, [0.0, -1.0, 0.0])

    edge_world = combine(image_x_world, :math.cos(angle), image_y_world, :math.sin(angle))

    edge_tangent_world =
      SpatialArithmetics.project_onto_tangent_plane(edge_world, surface_normal)

    edge_tangent_world =
      if magnitude(edge_tangent_world) < Math.default_tolerance() do
        TangentFrame.basis_u(tangent_frame)
      else
        SpatialArithmetics.normalize(edge_tangent_world)
      end

    in_plane =
      SpatialArithmetics.normalize([
        dot(edge_tangent_world, TangentFrame.basis_u(tangent_frame)),
        dot(edge_tangent_world, TangentFrame.basis_v(tangent_frame)),
        0.0
      ])

    [tangent_u, tangent_v, _zero] = in_plane

    SurfacePoseVectors.new([0.0, 0.0, 1.0], in_plane, [-tangent_v, tangent_u, 0.0])
  end

  defp rotate(matrix, vector), do: Enum.map(matrix, &dot(&1, vector))

  defp combine(first, first_scale, second, second_scale) do
    first
    |> Enum.zip(second)
    |> Enum.map(fn {a, b} -> a * first_scale + b * second_scale end)
  end

  defp dot(first, second) do
    first
    |> Enum.zip(second)
    |> Enum.map(fn {a, b} -> a * b end)
    |> Enum.sum()
  end

  defp magnitude(vector), do: vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
end
