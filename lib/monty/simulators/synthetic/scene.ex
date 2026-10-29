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

  # Habitat's camera field of view, which is what Monty's Habitat agents get and
  # what none of its configs override.
  @hfov 90.0

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
  What one ray saw: whether it hit the object, how far away it is, and the
  colour at that point.
  """
  @type observation :: %{
          on_object: boolean(),
          depth: float() | nil,
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
  What a sensor at `pose` sees through a pinhole camera.

  The camera is described the way Monty's own experiments describe it, so the
  studio's world is the experiment's camera rather than one chosen here: a
  `:resolution` of `{height, width}` pixels (a bare integer for a square patch),
  a `:zoom`, and a field of view `:hfov` in degrees. Monty's Habitat agents give
  a resolution and a zoom per sensor, and `DepthTo3DLocations` unprojects the
  image with `fx = tan(hfov / 2) / zoom`, so a world that rendered a different
  camera would make the transform disagree with it about which ray a pixel came
  from.

  A sensor looks along its own **−z**, as Monty's do, so its pose is enough: no
  separate gaze has to be passed in and kept consistent with it. Depth is
  measured along that axis, as a depth sensor measures it — not along the ray —
  so an off-axis pixel's depth is the distance to the plane through the surface
  point, which is what the transform assumes when it unprojects.

  One pixel is the default, and it is a real camera rather than a summary:
  depth, colour and semantic id come back as images, which is the shape Monty's
  own code indexes. With one pixel the grid has a single sample at the axis, so
  the field of view does not matter.

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
    {height, width} = resolution(Keyword.get(options, :resolution, 1))

    {fx, fy} =
      focal_lengths(
        {height, width},
        Keyword.get(options, :hfov, @hfov),
        Keyword.get(options, :zoom, 1.0)
      )

    rows =
      for row <- 0..(height - 1) do
        for column <- 0..(width - 1) do
          ray(origin, rotation, row, column, {height, width}, {fx, fy})
          |> then(&observation_of_ray(scene, &1))
        end
      end

    %{
      depth: Enum.map(rows, fn row -> Enum.map(row, &(&1.depth || 0.0)) end),
      rgba: Enum.map(rows, fn row -> Enum.map(row, &(&1.rgba || @no_colour)) end),
      semantic:
        Enum.map(rows, fn row -> Enum.map(row, &if(&1.on_object, do: 1.0, else: 0.0)) end),
      centre: rows |> Enum.at(div(height, 2)) |> Enum.at(div(width, 2))
    }
  end

  @doc """
  The middle pixel of a view, as a camera would answer it.

  Answers the depth, colour and semantic id of one pixel — what
  `Monty.Frameworks.EnvironmentUtils.Transforms.DepthTo3DLocations` unprojects,
  and what a policy asking "how far away is the thing in front of me?" reads. The
  middle pixel of a wide patch is not its axis — only a one-pixel camera or an odd
  count puts a pixel there — so this renders rather than assuming.
  """
  @spec observe(t(), %{position: Rotation.vector(), rotation: Rotation.t()}) :: observation()
  def observe(%__MODULE__{} = scene, pose), do: render(scene, pose).centre

  # A pinhole camera in Monty's terms. `fx = tan(hfov / 2) / zoom` is the half
  # width of the image plane at unit distance, which is exactly what Monty's
  # `DepthTo3DLocations` inverts; `fy` differs from it only for a patch that is
  # not square.
  defp focal_lengths({height, width}, hfov, zoom) do
    fx = :math.tan(radians(hfov) / 2.0) / zoom
    {fx, fx * height / width}
  end

  defp resolution({height, width}) when is_integer(height) and is_integer(width),
    do: {height, width}

  defp resolution(size) when is_integer(size) and size > 0, do: {size, size}

  # The ray through a pixel, and how much shorter the depth along the sensor's
  # axis is than the distance along the ray.
  defp ray(origin, rotation, row, column, {height, width}, {fx, fy}) do
    across = across(column, width) * fx
    down = down(row, height) * fy
    direction = Rotation.apply(rotation, SpatialArithmetics.normalize([across, down, -1.0]))

    {origin, direction, 1.0 / :math.sqrt(1.0 + across * across + down * down)}
  end

  # Monty's pixel grid: `linspace(-1, 1, width)` across and
  # `linspace(1, -1, height)` down, so the ends of the image are the ends of the
  # grid. A single pixel is the axis.
  defp across(column, width), do: grid(column, width)
  defp down(row, height), do: -grid(row, height)

  defp grid(_index, 1), do: 0.0
  defp grid(index, count), do: -1.0 + 2.0 * index / (count - 1)

  defp observation_of_ray(scene, {origin, gaze, axis_scale}) do
    case first_hit(scene, origin, gaze) do
      nil ->
        %{on_object: false, depth: nil, rgba: nil}

      {distance, point} ->
        %{on_object: true, depth: distance * axis_scale, rgba: colour(scene, point)}
    end
  end

  # The colour of the surface at `point`. One object, one colour, so the point
  # itself only matters for a scene that later has more than one.
  defp colour(scene, _point), do: scene.rgb ++ [1.0]

  defp radians(degrees), do: degrees * :math.pi() / 180.0

  # How far along the gaze the surface is, and where that is. A ray that misses,
  # or that only meets the sphere behind the sensor, sees nothing.
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
        nil ->
          nil

        distance ->
          {distance, SpatialArithmetics.add(origin, SpatialArithmetics.scale(gaze, distance))}
      end
    end
  end
end
