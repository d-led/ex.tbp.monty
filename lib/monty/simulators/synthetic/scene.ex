defmodule Monty.Simulators.Synthetic.Scene do
  @moduledoc """
  The one object the stand-in world has, and what a sensor sees of it.

  A sphere, because a sphere is the simplest surface whose depth, normal and
  curvature are all exact: the ray from a sensor either misses it, and the sensor
  is looking at nothing, or hits it, and the distance, the outward normal and the
  two principal curvatures follow in closed form. Anything a surface policy does
  — following curvature, avoiding places it has been, re-orienting against a
  normal — can be exercised against it, which is the whole point of having it.

  The conventions are Monty's, from
  `frameworks/utils/sensor_processing.principal_curvatures`:

    * a convex surface has **negative** principal curvatures (Monty's own TODO
      says it would rather they were positive; the sign is reproduced);
    * the curvatures are ordered largest first, which for a sphere is a tie;
    * `dir2` is the right-hand partner of `dir1` about the normal, so
      `dir1 × dir2 = normal`.

  What it is not: an object. A run against this scene says nothing about
  recognition; it says whether the body and the world agree about where the
  agent is and what it is looking at.
  """

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Geometry.Rotation

  @centre [0.0, 0.0, 0.0]
  @radius 0.05
  @rgb [0.2, 0.7, 0.2]

  # What a depth image has where the camera saw nothing: no depth, and a colour
  # that belongs to nothing.
  @no_colour [0.0, 0.0, 0.0, 1.0]

  @enforce_keys [:centre, :radius, :rgb]
  defstruct [:centre, :radius, :rgb]

  @type t :: %__MODULE__{
          centre: Rotation.vector(),
          radius: float(),
          rgb: [float()]
        }

  @typedoc """
  What one sensor sees: whether it hit the object, how far away it is, the
  surface it hit, and the colour at that point.
  """
  @type observation :: %{
          on_object: boolean(),
          depth: float() | nil,
          principal_curvatures: [float()] | nil,
          pose_vectors: {Rotation.vector(), Rotation.vector(), Rotation.vector()} | nil,
          rgba: [float()] | nil
        }

  @doc """
  A scene with `:radius` metres of sphere at `:centre`, coloured `:rgb`.

  A centimetre-radius ball would be too small for a 2.5 cm standoff; Monty's
  objects are of the order of a few centimetres, so five is a fair stand-in.
  The colour is arbitrary — there is one object and it is all one colour — but
  it exists because Monty's sensor modules report `hsv`, and experiments weight
  it: a world with no colour would leave that feature empty.
  """
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{
      centre: Keyword.get(options, :centre, @centre),
      radius: Keyword.get(options, :radius, @radius),
      rgb: Keyword.get(options, :rgb, @rgb)
    }
  end

  @doc """
  What a sensor at `pose` sees through a camera of `:resolution` pixels across
  and `:field_of_view` degrees wide.

  A sensor looks along its own **−z**, as Monty's do, so its pose is enough: no
  separate gaze has to be passed in and kept consistent with it. The centre
  pixel of an odd resolution is the ray straight down that axis.

  A one-pixel camera at no field of view is the default, and it is a real
  camera rather than a summary: depth, colour and semantic id come back as
  images, which is the shape Monty's own code indexes.

  A ray that misses sees nothing: depth 0, which is what a depth image has where
  the camera saw nothing, and a semantic id of 0. That is a difference from
  Monty's worlds rather than a simplification — theirs are enclosed, so a camera
  pointed anywhere sees a floor, a wall or a ceiling at some distance, and a
  surface agent's search for a lost object relies on that
  (`docs/monty-bugs.md` §1.7). Here there is nothing behind the object.
  """
  @spec render(t(), %{position: Rotation.vector(), rotation: Rotation.t()}, keyword()) :: %{
          depth: [[float()]],
          rgba: [[[float()]]],
          semantic: [[float()]],
          centre: observation()
        }
  def render(%__MODULE__{} = scene, %{position: origin, rotation: rotation}, options \\ []) do
    resolution = Keyword.get(options, :resolution, 1)
    field_of_view = Keyword.get(options, :field_of_view, 0.0)

    rows =
      for row <- 0..(resolution - 1) do
        for column <- 0..(resolution - 1) do
          ray(origin, rotation, row, column, resolution, field_of_view)
          |> then(&observation_of_ray(scene, &1))
        end
      end

    %{
      depth: Enum.map(rows, fn row -> Enum.map(row, &(&1.depth || 0.0)) end),
      rgba: Enum.map(rows, fn row -> Enum.map(row, &(&1.rgba || @no_colour)) end),
      semantic:
        Enum.map(rows, fn row -> Enum.map(row, &if(&1.on_object, do: 1.0, else: 0.0)) end),
      centre: rows |> Enum.at(div(resolution, 2)) |> Enum.at(div(resolution, 2))
    }
  end

  @doc """
  What the middle of the view sees.

  The one thing a policy asks of a camera when it is not looking at the image:
  how far away the thing in front of it is.
  """
  @spec observe(t(), %{position: Rotation.vector(), rotation: Rotation.t()}) :: observation()
  def observe(%__MODULE__{} = scene, pose), do: render(scene, pose).centre

  # A pinhole camera: the ray through a pixel is its offset on the image plane
  # at unit distance, turned into the sensor's own frame. Pixels sit at the
  # middles of their cells, so the middle of an odd resolution is the axis.
  defp ray(origin, rotation, row, column, resolution, field_of_view) do
    half = :math.tan(radians(field_of_view) / 2.0)
    step = if resolution > 1, do: 2.0 * half / resolution, else: 0.0

    across = if resolution > 1, do: -half + step * (column + 0.5), else: 0.0
    down = if resolution > 1, do: -half + step * (row + 0.5), else: 0.0

    direction = Rotation.apply(rotation, SpatialArithmetics.normalize([across, down, -1.0]))
    {origin, direction}
  end

  defp observation_of_ray(scene, {origin, gaze}) do
    case first_hit(scene, origin, gaze) do
      nil ->
        %{on_object: false, depth: nil, principal_curvatures: nil, pose_vectors: nil, rgba: nil}

      {depth, point} ->
        %{
          on_object: true,
          depth: depth,
          principal_curvatures: curvatures(scene),
          pose_vectors: surface_frame(outward_normal(scene, point)),
          rgba: scene.rgb ++ [1.0]
        }
    end
  end

  defp radians(degrees), do: degrees * :math.pi() / 180.0

  # The distance along the gaze to the surface, and where that is. A ray that
  # misses, or that only meets the sphere behind the sensor, sees nothing.
  defp first_hit(scene, origin, gaze) do
    to_centre = SpatialArithmetics.subtract(origin, scene.centre)
    b = SpatialArithmetics.dot(gaze, to_centre)
    c = SpatialArithmetics.dot(to_centre, to_centre) - scene.radius * scene.radius
    discriminant = b * b - c

    if discriminant < 0.0 do
      nil
    else
      root = :math.sqrt(discriminant)

      case Enum.find([-b - root, -b + root], &(&1 > 0.0)) do
        nil -> nil
        depth -> {depth, SpatialArithmetics.add(origin, SpatialArithmetics.scale(gaze, depth))}
      end
    end
  end

  defp outward_normal(scene, point) do
    point |> SpatialArithmetics.subtract(scene.centre) |> SpatialArithmetics.normalize()
  end

  # A sphere curves the same amount in every direction, so both curvatures are
  # the same number and either direction is a curvature direction.
  defp curvatures(%__MODULE__{radius: radius}), do: [-1.0 / radius, -1.0 / radius]

  defp surface_frame(normal) do
    unit_normal = SpatialArithmetics.normalize(normal)
    reference = if abs(Enum.at(unit_normal, 2)) < 0.9, do: [0.0, 0.0, 1.0], else: [1.0, 0.0, 0.0]

    direction_1 =
      SpatialArithmetics.cross(reference, unit_normal) |> SpatialArithmetics.normalize()

    direction_2 =
      SpatialArithmetics.cross(unit_normal, direction_1) |> SpatialArithmetics.normalize()

    {unit_normal, direction_1, direction_2}
  end
end
