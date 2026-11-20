defmodule Monty.Frameworks.Environments.TwoDData.SaccadeOnImageEnvironment do
  @moduledoc """
  A world that is a photograph: the sensor's window saccades over a still image.

  Mirrors `tbp/monty/frameworks/environments/two_d_data.py::SaccadeOnImageEnvironment`.
  Monty's image world has no simulator in it. A scene is a directory holding
  `rgb_<version>.png` and `depth_<version>.data` — a colour image and the depth
  the same lens measured, both taken by an iPad — and an action moves a
  `patch_size` square over them: `look_up` and `look_down` along the image's
  rows, `turn_left` and `turn_right` along its columns, never leaving the border
  a patch can be taken at.

  The sensor's *position* is not a pixel index. Monty unprojects the whole depth
  image into a point cloud once per scene and answers, for the middle of the
  patch, the 3-D point under it — the model compares those points between steps,
  and a pixel index is not a distance. That unprojection is
  `Monty.Frameworks.EnvironmentUtils.Transforms.DepthTo3DLocations`, Monty's own
  transform, configured the way this class configures it: the whole image, every
  point, the iPad's 54.201° field of view, and anything past `depth_clip_value`
  treated as background.

  Two things are Monty's arithmetic rather than a choice this port made: anything
  in the depth image beyond 40 cm is dropped (its comment marks the number as a
  parameter nobody has tuned), and a missing return — a NaN — reads as ten
  metres, which is further than anything the clipping keeps.
  """

  @behaviour Monty.Simulators.Environment

  alias ExTbpMonty.Core.Png
  alias Monty.Frameworks.EnvironmentUtils.Transforms.DepthTo3DLocations
  alias Monty.Frameworks.EnvironmentUtils.Transforms.TransformContext
  alias Monty.Frameworks.Models.MotorSystemState.AgentState
  alias Monty.Frameworks.Models.MotorSystemState.SensorState
  alias Monty.Geometry.Rotation

  # The iPad front camera, which is what captured Monty's scenes.
  @hfov 54.201
  # A capture's depths that are further than this are the room, not the object.
  @far 0.4
  # What a depth image says where the camera got no return.
  @no_return 10.0
  @default_patch_size 64
  @depth_clip_value 1.1

  # Monty's own ids, because the point cloud is built with the transform as a
  # separate agent that stands at the origin looking at the image.
  @cloud_agent "agent_01"
  @cloud_sensor "patch_01"
  @agent_id "agent_id_0"
  @patch "patch"
  @view_finder "view_finder"

  @enforce_keys [:data_path, :scenes]
  defstruct patch_size: @default_patch_size,
            hfov: @hfov,
            depth_clip_value: @depth_clip_value,
            data_path: nil,
            scenes: [],
            scene: nil,
            version: 0,
            loc: nil,
            depth: nil,
            rgb: nil,
            point_cloud: nil,
            sensor_frame: nil,
            cam_to_world: nil,
            move_area: nil

  @type t :: %__MODULE__{
          patch_size: pos_integer(),
          hfov: float(),
          depth_clip_value: float(),
          data_path: Path.t(),
          scenes: [String.t()],
          scene: String.t() | nil,
          version: non_neg_integer(),
          loc: [integer()] | nil,
          depth: [[float()]] | nil,
          rgb: [[[integer()]]] | nil,
          point_cloud: [[tuple()]] | nil,
          sensor_frame: [[tuple()]] | nil,
          cam_to_world: map() | nil,
          move_area: [[integer()]] | nil
        }

  @doc """
  The world over the scenes in `:data_path`, started on the first of them.

  Options: `:data_path` (a directory of scenes, each a directory of
  `rgb_<version>.png` and `depth_<version>.data`), `:patch_size`,
  `:depth_clip_value`, `:hfov` and `:version`.
  """
  @impl true
  @spec new(keyword() | Path.t()) :: t()
  def new(data_path) when is_binary(data_path), do: new(data_path: data_path)

  def new(options) do
    data_path = options |> Keyword.fetch!(:data_path) |> to_string()
    scenes = data_path |> scene_names() |> scene_names_or_refuse(data_path)

    options
    |> environment(data_path, scenes)
    |> load_scene(hd(scenes), Keyword.get(options, :version, 0))
  end

  defp environment(options, data_path, scenes) do
    %__MODULE__{
      data_path: data_path,
      scenes: scenes,
      patch_size: Keyword.get(options, :patch_size, @default_patch_size),
      hfov: Keyword.get(options, :hfov, @hfov),
      depth_clip_value: Keyword.get(options, :depth_clip_value, @depth_clip_value)
    }
  end

  defp scene_names(data_path) do
    case File.ls(data_path) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.filter(&File.dir?(Path.join(data_path, &1)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp scene_names_or_refuse([], data_path) do
    raise ArgumentError,
          "#{data_path} holds no scene: an image world needs one directory per scene, " <>
            "each with rgb_<version>.png and depth_<version>.data"
  end

  defp scene_names_or_refuse(scenes, _data_path), do: scenes

  @doc """
  The next observation, after `actions` have moved the sensor's window.

  A step is Monty's: an action that is not one of the four saccades does not
  move, a turn of less than one pixel is one pixel, and the answer is the
  observation at the place that was reached.
  """
  @impl true
  def step(%__MODULE__{} = environment, actions) do
    environment =
      Enum.reduce(actions, environment, fn action, environment ->
        move(environment, action)
      end)

    {observations(environment), state(environment), environment}
  end

  defp move(environment, action) do
    amount =
      action
      |> rotation_degrees()
      |> then(fn amount -> if abs(amount) < 1, do: 1, else: amount end)
      |> trunc()

    %{environment | loc: get_next_loc(environment, action_name(action), amount)}
  end

  defp action_name(%{name: name}) when is_binary(name), do: name
  defp action_name(%{"name" => name}) when is_binary(name), do: name
  defp action_name(name) when is_binary(name), do: name
  defp action_name(%{action: name}), do: action_name(name)

  defp rotation_degrees(%{rotation_degrees: degrees}) when is_number(degrees), do: degrees
  defp rotation_degrees(%{"rotation_degrees" => degrees}) when is_number(degrees), do: degrees
  defp rotation_degrees(_action), do: 0

  @doc """
  The world a fresh episode starts in: the same scene, from the middle of it.
  """
  @impl true
  def reset(%__MODULE__{} = environment),
    do: load_scene(environment, environment.scene, environment.version)

  @doc """
  Loads another capture of the same scene, or of another one.

  Monty calls this with the object it wants to see: `scene_id` indexes the sorted
  scene names, `scene_version_id` picks which capture of it.
  """
  @spec switch_to_object(t(), non_neg_integer(), non_neg_integer()) :: t()
  def switch_to_object(%__MODULE__{scenes: scenes} = environment, scene_id, scene_version_id) do
    load_scene(environment, Enum.at(scenes, scene_id), scene_version_id)
  end

  @doc """
  The scene's images, its starting window, and the point cloud built from its
  depth.
  """
  @spec load_new_scene_data(t()) :: t()
  def load_new_scene_data(%__MODULE__{} = environment) do
    rgb_path =
      Path.join([environment.data_path, environment.scene, "rgb_#{environment.version}.png"])

    depth_path =
      Path.join([environment.data_path, environment.scene, "depth_#{environment.version}.data"])

    rgb = load_rgb_data(rgb_path)
    height = length(rgb)
    width = rgb |> hd() |> length()

    environment = %{
      environment
      | rgb: rgb,
        depth: depth_path |> load_depth_data(height, width) |> process_depth_data()
    }

    environment
    |> Map.put(:loc, start_location(environment))
    |> Map.put(:move_area, get_move_area(environment))
    |> get_3d_scene_point_cloud()
  end

  @doc """
  A capture's depth as rows of metres: raw little-endian float32, `width` to a
  row, as `np.fromfile(path, np.float32).reshape(height, width)` reads it.

  A word that is not a number is a missing return, which is where Monty's
  `process_depth_data` does that substitution — the port does it here, because
  the BEAM has no NaN to substitute later (`docs/monty-differences.md` §2.33): a
  float segment cannot even match one, so reading the file is the last place that
  can see it.
  """
  # `path` is a scene's own file, built from the data directory the caller named
  # and the scene the world is on — not anything a browser or a config's value
  # supplies at read time.
  # sobelow_skip ["Traversal.FileModule"]
  @spec load_depth_data(Path.t(), non_neg_integer(), non_neg_integer()) :: [[float()]]
  def load_depth_data(path, height, width) do
    path
    |> File.read!()
    |> depths()
    |> Enum.chunk_every(width)
    |> Enum.take(height)
  end

  defp depths(bytes) do
    for <<word::binary-size(4) <- bytes>>, do: depth(:binary.decode_unsigned(word, :little))
  end

  # A 32-bit word whose exponent is all ones is a NaN or an infinity, and neither
  # is a distance: the first is what a depth camera says where it got no return.
  defp depth(word) do
    case <<word::32>> do
      <<_sign::1, 0xFF::8, _mantissa::23>> -> @no_return
      <<value::float-32>> -> value
    end
  end

  @doc """
  Depth as a sensor can use it: no returns and the room read as ten metres.

  Monty clips anything past 40 cm before matching, and this is where that
  happens — on the image, so that the point cloud and the depth a sensor module
  sees agree about which pixels are the object.
  """
  @spec process_depth_data([[float()]]) :: [[float()]]
  def process_depth_data(rows) do
    Enum.map(rows, fn row -> Enum.map(row, &processed_depth/1) end)
  end

  defp processed_depth(value) when value > @far, do: @no_return
  defp processed_depth(value), do: value

  @doc """
  A capture's colour as rows of pixels, four channels a pixel.

  `np.array(PIL.Image.open(path))` is what Monty has here, so the shape is
  `height × width × channels` and the values are 0..255.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec load_rgb_data(Path.t()) :: [[[non_neg_integer()]]]
  def load_rgb_data(path) do
    case path |> File.read!() |> Png.decode() do
      {:ok, image} ->
        pixels_of(image)

      {:error, reason} ->
        raise ArgumentError, "#{path} is not a capture this port can read: #{reason}"
    end
  end

  defp pixels_of(%{width: width, height: height, channels: channels, pixels: pixels}) do
    for row <- 0..(height - 1) do
      for column <- 0..(width - 1) do
        at = (row * width + column) * channels
        for channel <- 0..(channels - 1), do: :binary.at(pixels, at + channel)
      end
    end
  end

  defp start_location(environment) do
    [div(length(environment.depth), 2), div(environment.depth |> hd() |> length(), 2)]
  end

  @doc """
  Where the middle of a patch may be: far enough from the border that a patch is
  still a patch.
  """
  @spec get_move_area(t()) :: [[integer()]]
  def get_move_area(%__MODULE__{} = environment) do
    height = length(environment.depth)
    width = environment.depth |> hd() |> length()
    half = div(environment.patch_size, 2) + 1

    [[half, height - half], [half, width - half]]
  end

  @doc """
  Where an action takes the window, kept inside the move area.

  Monty's axes: `look_up` and `look_down` move along the image's rows (up is
  smaller), `turn_left` and `turn_right` along its columns. An action that is not
  one of the four moves nothing.
  """
  @spec get_next_loc(t(), String.t() | atom(), integer()) :: [integer()]
  def get_next_loc(%__MODULE__{loc: [row, column]} = environment, action_name, amount) do
    moved =
      case to_string(action_name) do
        "look_up" -> [row - amount, column]
        "look_down" -> [row + amount, column]
        "turn_left" -> [row, column - amount]
        "turn_right" -> [row, column + amount]
        _not_a_saccade -> [row, column]
      end

    [[low_row, high_row], [low_column, high_column]] = environment.move_area

    [
      moved |> Enum.at(0) |> clamp(low_row, high_row),
      moved |> Enum.at(1) |> clamp(low_column, high_column)
    ]
  end

  defp clamp(value, low, _high) when value < low, do: low
  defp clamp(value, _low, high) when value > high, do: high
  defp clamp(value, _low, _high), do: value

  @doc """
  The four pictures a patch is: its depth, its colour, its points in the world and
  its points in the sensor's own frame.

  The points are flat — one row per pixel — because that is the shape a sensor
  module's `"semantic_3d"` has.
  """
  @spec get_image_patch(t(), [integer()]) ::
          {[[float()]], [[[non_neg_integer()]]], [tuple()], [tuple()]}
  def get_image_patch(%__MODULE__{} = environment, [row, column]) do
    half = div(environment.patch_size, 2)
    window = (row - half)..(row + half - 1)

    depth = patch(environment.depth, window, half, column)
    rgb = patch(environment.rgb, window, half, column)
    world = patch(environment.point_cloud, window, half, column)
    sensor = patch(environment.sensor_frame, window, half, column)

    {depth, rgb, Enum.concat(world), Enum.concat(sensor)}
  end

  defp patch(image, window, half, column) do
    Enum.map(window, fn row ->
      Enum.slice(Enum.at(image, row), (column - half)..(column + half - 1))
    end)
  end

  @doc """
  The point under a pixel of the scene, in the world.
  """
  @spec get_3d_coordinates_from_pixel_indices(t(), [integer()]) :: [float()]
  def get_3d_coordinates_from_pixel_indices(%__MODULE__{point_cloud: cloud}, [row, column]) do
    [x, y, z | _on_surface] = cloud |> Enum.at(row) |> Enum.at(column)
    [x, y, z]
  end

  @doc """
  Unprojects the scene's depth into points, once per scene.

  The transform is Monty's own, configured the way this class configures it, and
  it is called with a state of its own: an agent at the origin, looking straight
  along the image, because a captured scene's pose is what the image *is* — there
  is no camera to ask.

  What it answers is used twice: the whole point cloud (a pixel's place, for a
  position), and the same points in the sensor's frame (a point cloud, for a
  surface agent's later steps). `cam_to_world` is kept with them, because a
  sensor module reads it when the world's frame is not the sensor's.
  """
  @spec get_3d_scene_point_cloud(t()) :: t()
  def get_3d_scene_point_cloud(%__MODULE__{} = environment) do
    height = length(environment.depth)
    width = environment.depth |> hd() |> length()

    transform =
      DepthTo3DLocations.new(
        agent_id: @cloud_agent,
        sensor_ids: [@cloud_sensor],
        resolutions: [{height, width}],
        hfov: environment.hfov,
        world_coord: true,
        get_all_points: true,
        depth_clip_sensors: [0],
        clip_value: environment.depth_clip_value
      )

    %{@cloud_agent => %{@cloud_sensor => answer}} =
      DepthTo3DLocations.call(
        %{@cloud_agent => %{@cloud_sensor => %{"depth" => environment.depth}}},
        transform,
        %TransformContext{rng: nil, state: viewing_state()}
      )

    %{
      environment
      | point_cloud: reshape(answer["semantic_3d"], width),
        sensor_frame: reshape(answer["sensor_frame_data"], width),
        cam_to_world: answer["cam_to_world"]
    }
  end

  defp reshape(flat, width), do: Enum.chunk_every(flat, width)

  defp viewing_state do
    {:ok, rotation} = Rotation.from_axis_angle([1.0, 0.0, 0.0], :math.pi() / 2.0)
    position = [0.0, 0.0, 0.0]
    sensor = %SensorState{position: position, rotation: rotation}

    %{
      @cloud_agent => %AgentState{
        sensors: %{@cloud_sensor => sensor},
        position: position,
        rotation: rotation
      }
    }
  end

  @doc """
  What the sensors see at the window's place.

  Monty answers two sensors and so does this: the patch, which is the point on
  the surface and its colour, and the view finder, which is the whole capture.
  """
  @spec observations(t()) :: map()
  def observations(%__MODULE__{} = environment) do
    {depth, rgb, world, sensor_frame} = get_image_patch(environment, environment.loc)

    %{
      @agent_id => %{
        @patch => %{
          "depth" => depth,
          "rgba" => rgb,
          "semantic_3d" => world,
          "sensor_frame_data" => sensor_frame,
          "cam_to_world" => environment.cam_to_world,
          "pixel_loc" => environment.loc
        },
        @view_finder => %{
          "depth" => environment.depth,
          "rgba" => environment.rgb
        }
      }
    }
  end

  @doc """
  Where the sensors are: the point under the middle of the window.

  A pixel index is not a distance, so Monty answers the 3-D point under the
  patch's middle — the model compares the positions of two steps, and pixels
  would be a different quantity.
  """
  @spec state(t()) :: map()
  def state(%__MODULE__{} = environment) do
    position = get_3d_coordinates_from_pixel_indices(environment, environment.loc)
    # An image is presented upright, so a patch and the agent that carries it have
    # the same rotation — Monty's own comment on the value.
    {:ok, rotation} = Rotation.from_axis_angle([1.0, 0.0, 0.0], :math.pi() / 2.0)
    sensor = %SensorState{position: position, rotation: rotation}

    %{
      @agent_id => %AgentState{
        sensors: %{@patch => sensor, @view_finder => sensor},
        position: [0.0, 0.0, 0.0],
        rotation: rotation
      }
    }
  end

  @impl true
  def stop(%__MODULE__{}), do: :ok

  @impl true
  def positions_itself?, do: false

  defp load_scene(environment, scene, version) do
    environment
    |> Map.put(:scene, scene)
    |> Map.put(:version, version)
    |> load_new_scene_data()
  end
end
