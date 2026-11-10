defmodule Monty.Frameworks.EnvironmentUtils.Transforms.DepthTo3DLocations do
  @moduledoc """
  A depth image becomes points in the world, and a mask of which pixels are on
  the surface the camera is pointed at.

  Mirrors `tbp/monty/frameworks/environment_utils/transforms.py::DepthTo3DLocations`.
  Monty's sensor modules never see a depth image: they see `"semantic_3d"`, one
  row per pixel with its three coordinates and whether that pixel is on the
  surface in the middle of the view, and `"cam_to_world"`, the frame those
  coordinates are expressed in. This transform is what puts them there, and
  every one of Monty's experiments configures it directly after
  `MissingToMaxDepth`.

  ## On-object is not on-surface

  A camera sees parts of an object that are far from each other: the front lip
  of a mug and its back lip are both the mug, and a surface normal fitted across
  the two is a normal of nothing. So the mask is built in two steps. Pixels are
  **on-object** if the depth image (or a semantic sensor) says so; they are
  **on-surface** if they are on-object *and* locally at the depth of the middle
  of the view — anything beyond a threshold is another surface and is masked
  out. When the depths in the patch have a bimodal distribution there is a
  threshold between the modes, and the mask keeps the mode the middle pixel is
  in; when they do not, the threshold is the sensor's own reach (`clip_value`
  for a surface agent, a kilometre for a distant one).

  For a surface agent the depth and object masks are also **clipped**: Monty's
  fingers have a short reach, so anything at or beyond `clip_value` stops being
  object and every depth beyond it becomes `clip_value`. A depth of 0 — "no
  return" — becomes `clip_value` too, which is why the clipping happens on the
  image rather than on the points.

  ## What it assumes

  A pinhole camera, as Monty's does. The half width of the image plane at unit
  distance is `fx = tan(hfov / 2) / zoom`, and a pixel at `(x, y)` of the
  normalised grid with depth `d` is the point `(x d fx, y d fy, -d)` in the
  sensor's frame. The grid is Monty's own, `linspace(-1, 1, width)` across and
  `linspace(1, -1, height)` down — the edges of the image rather than its pixel
  centres (`docs/monty-differences.md` §1.8) — so a simulator rendering this world has
  to sample the same rays this transform unprojects. That pairing is what
  `Monty.Simulators.Synthetic.Scene` keeps, and what its test of rebuilt points
  checks.
  """

  @behaviour Monty.Frameworks.EnvironmentUtils.Transforms.Transform

  alias Monty.Frameworks.EnvironmentUtils.Transforms.TransformContext
  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.Geometry
  alias Monty.Geometry.Rotation

  # Habitat's field of view, which Monty's agents take as given.
  @hfov 90.0
  # How near a surface agent's finger reaches, and how far from the middle of the
  # view a pixel may be and still be the same surface.
  @clip_value 0.05
  @min_depth_range 0.01
  # A distant agent is not on a surface at all, so its threshold is infinite for
  # the purpose of masking.
  @distant_on_surface_threshold 1000.0
  @histogram_bins 8
  # One count per bin, before any depth has been counted.
  @no_depths_counted List.to_tuple(List.duplicate(0, @histogram_bins))

  @enforce_keys [:agent_id, :sensor_ids, :intrinsics]
  defstruct agent_id: nil,
            sensor_ids: [],
            intrinsics: [],
            clip_value: @clip_value,
            depth_clip_sensors: [],
            world_coord: true,
            get_all_points: false,
            use_semantic_sensor: false

  @typedoc """
  What one sensor's camera is, in the terms the unprojection needs.
  """
  @type intrinsic :: %{height: pos_integer(), width: pos_integer(), fx: float(), fy: float()}

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          sensor_ids: [Monty.Simulators.Environment.sensor_id()],
          intrinsics: [intrinsic()],
          clip_value: float(),
          depth_clip_sensors: [non_neg_integer()],
          world_coord: boolean(),
          get_all_points: boolean(),
          use_semantic_sensor: boolean()
        }

  @doc """
  The transform, from the cameras its sensors look through.

  Options: `:agent_id`, `:sensor_ids`, and a camera per sensor — `:resolutions`
  as `{height, width}` pairs, `:zooms` and `:hfov`, each either one value for
  every sensor or one per sensor, as Monty takes them. Then `:clip_value`,
  `:depth_clip_sensors`, `:world_coord`, `:get_all_points` and
  `:use_semantic_sensor`.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    sensor_ids = Keyword.fetch!(options, :sensor_ids)
    zooms = per_sensor(Keyword.get(options, :zooms, 1.0), length(sensor_ids))
    hfovs = per_sensor(Keyword.get(options, :hfov, @hfov), length(sensor_ids))

    %__MODULE__{
      agent_id: Keyword.fetch!(options, :agent_id),
      sensor_ids: sensor_ids,
      intrinsics:
        Enum.zip_with([Keyword.fetch!(options, :resolutions), zooms, hfovs], &intrinsic/1),
      clip_value: Keyword.get(options, :clip_value, @clip_value),
      depth_clip_sensors: Keyword.get(options, :depth_clip_sensors, []),
      world_coord: Keyword.get(options, :world_coord, true),
      get_all_points: Keyword.get(options, :get_all_points, false),
      use_semantic_sensor: Keyword.get(options, :use_semantic_sensor, false)
    }
  end

  @doc """
  The transform a config describes.
  """
  @spec from_config(map()) :: t()
  def from_config(config) do
    new(
      agent_id: Map.fetch!(config, "agent_id"),
      sensor_ids: Map.fetch!(config, "sensor_ids"),
      resolutions: config |> Map.fetch!("resolutions") |> Enum.map(&as_resolution/1),
      zooms: Map.get(config, "zooms", 1.0),
      hfov: Map.get(config, "hfov", @hfov),
      clip_value: Map.get(config, "clip_value", @clip_value),
      depth_clip_sensors: Map.get(config, "depth_clip_sensors", []),
      world_coord: Map.get(config, "world_coord", true),
      get_all_points: Map.get(config, "get_all_points", false),
      use_semantic_sensor: Map.get(config, "use_semantic_sensor", false)
    )
  end

  @impl true
  @spec call(map(), t(), Monty.Frameworks.EnvironmentUtils.Transforms.TransformContext.t()) ::
          map()
  def call(observations, %__MODULE__{} = transform, %TransformContext{} = ctx) do
    case Map.fetch(observations, transform.agent_id) do
      {:ok, sensors} ->
        agent_state = agent_state(ctx.state, transform.agent_id)

        transformed =
          transform.sensor_ids
          |> Enum.with_index()
          |> Enum.reduce(sensors, fn {sensor_id, index}, sensors ->
            case Map.fetch(sensors, sensor_id) do
              {:ok, observation} ->
                Map.put(
                  sensors,
                  sensor_id,
                  transform_observation(observation, sensor_id, index, transform, agent_state)
                )

              :error ->
                sensors
            end
          end)

        Map.put(observations, transform.agent_id, transformed)

      :error ->
        observations
    end
  end

  @doc """
  Which pixels are on the surface the middle of the view is pointed at.

  Takes the depth image and the on-object mask, and answers a mask of the same
  shape: 1 where a pixel is on that surface, 0 where it is not.
  """
  @spec get_surface_from_depth([[float()]], [[float()]], float()) :: [[float()]]
  def get_surface_from_depth(depth, semantic, default_threshold) do
    # Seeing the table goes up to almost a hundred metres, and eight bins over
    # that range would separate nothing, so anything past a metre is a metre.
    near = Enum.map(depth, fn row -> Enum.map(row, &min(&1, 1.0)) end)

    # Nothing in view is nearer than a metre: asked row by row, because the
    # answer is only yes or no and flattening the image to ask costs four
    # thousand list steps.
    if near |> Enum.all?(fn row -> Enum.all?(row, &(&1 >= 1.0)) end) do
      Enum.map(near, fn row -> Enum.map(row, fn _pixel -> 0.0 end) end)
    else
      {threshold, flip?} = get_on_surface_th(near, semantic, @min_depth_range, default_threshold)
      keep(depth, semantic, threshold, flip?)
    end
  end

  # On the surface *and* on the object: a pixel of the surface in front of the
  # one the camera is pointed at is still not part of it.
  defp keep(depth, semantic, threshold, flip?) do
    zip_map(depth, semantic, fn depth_row, semantic_row ->
      zip_map(depth_row, semantic_row, fn pixel, on_object ->
        if on_surface?(pixel, threshold, flip?) and on_object > 0.0, do: 1.0, else: 0.0
      end)
    end)
  end

  # Two equally shaped lists, element by element, which is the two-list case of
  # `Enum.zip_with/2` — same order, same length (the shorter list decides) —
  # without its machinery. A step walks a 64x64 patch through here pixel by
  # pixel, and for each one the generic zipper built the list of the two, a
  # reversed accumulator and two `lists:all` checks; the zipping alone was a
  # fifth of a transform's time.
  defp zip_map([a | as], [b | bs], fun), do: [fun.(a, b) | zip_map(as, bs, fun)]
  defp zip_map([], _b, _fun), do: []
  defp zip_map(_a, [], _fun), do: []

  @doc """
  The depth threshold that separates two surfaces in the view, and which side of
  it to keep.

  Only a bimodal distribution of depths is worth separating: if the whole patch
  spans less than `min_depth_range` there is one surface, and the sensor's own
  default threshold applies. `flip?` says the middle of the view is on the far
  surface, so the pixels to keep are the ones beyond the threshold rather than
  the ones in front of it.
  """
  @spec get_on_surface_th([[float()]], [[float()]], float(), float()) :: {float(), boolean()}
  def get_on_surface_th(depth, semantic, min_depth_range, default_threshold) do
    depths = List.flatten(depth)
    {low, high} = Enum.min_max(depths)

    if high - low <= min_depth_range do
      {default_threshold, false}
    else
      case empty_bins(depths, low, high) do
        [] ->
          {default_threshold, false}

        empty ->
          threshold = Enum.at(empty, div(length(empty), 2))
          {threshold, middle_pixel(depth) > threshold and middle_pixel(semantic) > 0.0}
      end
    end
  end

  # -- one sensor's observation ----------------------------------------------

  defp transform_observation(observation, sensor_id, index, transform, agent_state) do
    depth = depth_image(observation, sensor_id)
    semantic = on_object(observation, depth)
    {depth, semantic} = clip(depth, semantic, index, transform)
    surface = surface_mask(depth, semantic, index, transform)
    sensor_frame_data = unproject(depth, Enum.at(transform.intrinsics, index))
    frame = camera_frame(agent_state, sensor_id)

    {points, observation} =
      if transform.world_coord and frame != nil do
        {Enum.map(sensor_frame_data, &to_world(&1, frame)),
         Map.put(observation, "cam_to_world", cam_to_world(frame))}
      else
        {sensor_frame_data, observation}
      end

    # The mask is flattened once for both sets of points — the world's and the
    # sensor frame's — because both are tagged with the same mask and flattening
    # a 64x64 image is four thousand list steps.
    mask = List.flatten(surface)

    observation
    |> Map.put("depth", depth)
    |> put_clipped_semantic(semantic)
    |> Map.put("semantic_3d", tagged_points(points, mask, transform.get_all_points))
    |> put_sensor_frame_data(sensor_frame_data, mask, transform.get_all_points)
  end

  defp depth_image(observation, sensor_id) do
    case Map.fetch(observation, "depth") do
      {:ok, depth} ->
        depth

      :error ->
        raise ArgumentError, "sensor #{inspect(sensor_id)} has no depth image to unproject"
    end
  end

  # A semantic sensor's own image is the object mask, and this transform clips it
  # in place; a sensor without one is not given a key it did not have.
  defp put_clipped_semantic(observation, semantic) do
    if Map.has_key?(observation, "semantic"),
      do: Map.put(observation, "semantic", semantic),
      else: observation
  end

  defp put_sensor_frame_data(observation, _points, _mask, false), do: observation

  defp put_sensor_frame_data(observation, points, mask, true),
    do: Map.put(observation, "sensor_frame_data", tagged_points(points, mask, true))

  # The on-object mask: the semantic sensor's own answer when the experiment
  # reads one, and otherwise the depth image's — a pixel a metre away or more is
  # not the object, because `MissingToMaxDepth` has already replaced everything
  # the camera could not see.
  defp on_object(observation, depth) do
    case Map.fetch(observation, "semantic") do
      {:ok, semantic} -> semantic
      :error -> Enum.map(depth, fn row -> Enum.map(row, &if(&1 >= 1.0, do: 0.0, else: 1.0)) end)
    end
  end

  # A surface agent's finger does not reach past `clip_value`, so nothing beyond
  # it is object and every depth beyond it — or of zero, which is no return — is
  # as far as the finger goes.
  defp clip(depth, semantic, index, transform) do
    if index in transform.depth_clip_sensors do
      clip_value = transform.clip_value
      {clip_depths(depth, clip_value), clip_objects(depth, semantic, clip_value)}
    else
      {depth, semantic}
    end
  end

  defp clip_depths(depth, clip_value) do
    Enum.map(depth, fn row ->
      Enum.map(row, fn pixel ->
        if pixel == 0.0 or pixel > clip_value, do: clip_value, else: pixel
      end)
    end)
  end

  defp clip_objects(depth, semantic, clip_value) do
    zip_map(depth, semantic, fn depth_row, semantic_row ->
      zip_map(depth_row, semantic_row, fn
        pixel, _on_object when pixel >= clip_value -> 0.0
        _pixel, on_object -> on_object
      end)
    end)
  end

  # A surface agent that reads a semantic sensor already knows which pixels are
  # object, so its clipped mask is used as it is; everything else has to be
  # separated into surfaces by depth. Both are cases Monty has, and the first is
  # noted there as one it rarely takes.
  defp surface_mask(depth, semantic, index, transform) do
    if transform.depth_clip_sensors != [] and transform.use_semantic_sensor do
      semantic
    else
      get_surface_from_depth(depth, semantic, default_threshold(index, transform))
    end
  end

  defp default_threshold(index, transform) do
    if index in transform.depth_clip_sensors,
      do: transform.clip_value,
      else: @distant_on_surface_threshold
  end

  # -- the geometry ----------------------------------------------------------

  defp intrinsic([{height, width}, zoom, hfov]) do
    fx = :math.tan(radians(hfov) / 2.0) / zoom
    %{height: height, width: width, fx: fx, fy: fx * height / width}
  end

  # `(x d fx, y d fy, -d)` for every pixel of the image, in Monty's order: row by
  # row, left to right.
  defp unproject(depth, intrinsic) do
    for {row_depths, row} <- Enum.with_index(depth),
        {pixel, column} <- Enum.with_index(row_depths) do
      [across(column, intrinsic) * pixel, down(row, intrinsic) * pixel, -pixel]
    end
  end

  defp across(column, %{width: width, fx: fx}), do: grid(column, width) * fx
  defp down(row, %{height: height, fy: fy}), do: -grid(row, height) * fy

  defp grid(_index, 1), do: 0.0
  defp grid(index, count), do: -1.0 + 2.0 * index / (count - 1)

  # The sensor's frame in the world. A sensor's rotation and position are
  # relative to its agent, so the agent's pose composes in front of them —
  # `rotation * sensor_rotation`, and the sensor's offset turned by the agent's
  # rotation before it is added to the agent's position.
  defp camera_frame(nil, _sensor_id), do: nil

  defp camera_frame(%AgentState{} = agent_state, sensor_id) do
    case Map.fetch(agent_state.sensors, sensor_id) do
      {:ok, sensor} ->
        agent_matrix = Rotation.to_matrix(agent_state.rotation)

        %{
          rotation: Rotation.to_matrix(Rotation.multiply(agent_state.rotation, sensor.rotation)),
          position:
            Geometry.add(agent_state.position, Geometry.apply(agent_matrix, sensor.position))
        }

      :error ->
        nil
    end
  end

  defp to_world(point, %{rotation: rotation, position: position}),
    do: Geometry.add(Geometry.apply(rotation, point), position)

  defp cam_to_world(%{rotation: rotation, position: position}) do
    placed = Enum.zip_with([rotation, position], fn [row, offset] -> row ++ [offset] end)
    placed ++ [[0.0, 0.0, 0.0, 1.0]]
  end

  # `mask` is the flattened surface mask: a pixel per point, in the order the
  # points are in.
  defp tagged_points(points, mask, all?) do
    tagged = zip_map(points, mask, fn point, on_surface -> point ++ [on_surface] end)

    if all?,
      do: tagged,
      else: for([_x, _y, _z, on_surface] = row <- tagged, on_surface != 0.0, do: row)
  end

  # -- the depth heuristics --------------------------------------------------

  defp on_surface?(pixel, threshold, false), do: pixel < threshold
  defp on_surface?(pixel, threshold, true), do: pixel > threshold

  # The edges numpy's `linspace` cuts: evenly spaced from the smallest depth to
  # the largest, and the last one *is* the largest. `low + width * bins` lands an
  # ulp below it often enough to matter, and a bin's upper edge short of the
  # largest depth would drop that depth from the histogram altogether.
  defp edges(low, width, high) do
    for(index <- 0..(@histogram_bins - 1), do: low + width * index) ++ [high]
  end

  # Numpy's histogram: `bins` counts over `bins + 1` edges from the smallest
  # depth to the largest, the last bin closed at both ends. The edges are evenly
  # spaced, so a depth's bin is arithmetic rather than a search of the edges.
  #
  # Answered as the lower edges of the empty bins, which is what the caller
  # needs: a peak either side of one is two surfaces in one view.
  defp empty_bins(depths, low, high) do
    width = (high - low) / @histogram_bins
    edges = List.to_tuple(edges(low, width, high))

    counts =
      Enum.reduce(depths, @no_depths_counted, fn depth, counts ->
        index = bin(depth, low, width, edges)
        put_elem(counts, index, elem(counts, index) + 1)
      end)

    for index <- 0..(@histogram_bins - 1), elem(counts, index) == 0, do: elem(edges, index)
  end

  # Numpy counts the interior edges a depth has reached, so a depth sitting
  # exactly on an edge opens the bin above it. The arithmetic estimate is one
  # comparison out of step at such an edge, and that is the comparison here.
  defp bin(depth, low, width, edges) do
    index = ((depth - low) / width) |> trunc() |> min(@histogram_bins - 1) |> max(0)

    cond do
      index < @histogram_bins - 1 and depth >= elem(edges, index + 1) -> index + 1
      index > 0 and depth < elem(edges, index) -> index - 1
      true -> index
    end
  end

  defp middle_pixel(image) do
    image
    |> Enum.at(div(length(image), 2))
    |> then(&Enum.at(&1, div(length(&1), 2)))
  end

  defp per_sensor(value, _count) when is_list(value), do: value
  defp per_sensor(value, count), do: List.duplicate(value, count)

  defp as_resolution([height, width]), do: {height, width}

  defp agent_state(nil, _agent_id), do: nil
  defp agent_state(state, agent_id), do: Map.get(state, agent_id)

  defp radians(degrees), do: degrees * :math.pi() / 180.0
end
