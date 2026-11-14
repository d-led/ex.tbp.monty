defmodule Monty.Simulators.ExMujoco.Scene do
  @moduledoc """
  An experiment's scene, as MJCF: the model `ex_mujoco` compiles.

  `priv/monty_py/world.py` builds the same scene through MuJoCo's spec API
  (`mjs_addBody`, `add_camera`, `add_geom`, `add_mesh` …). Here it is written as
  MuJoCo's own file format and parsed, which is the one way `ex_mujoco` builds a
  model — and it is the same scene: the same bodies, the same joints in the same
  order, the same cameras with the same field of view, and the same numbers for
  the scene itself (gravity, the offscreen buffer's size, the depth mapping's
  near and far, the headlight).

  What a scene holds: for each agent a body with a free joint and a sensor body
  hinged inside it with one camera per sensor, then the objects — a primitive
  geom, or a mesh with its texture and the metadata that says where its vertices
  are measured from. Nothing else moves: an agent is moved by the actions it is
  given and Monty's world calls `mj_forward` rather than stepping physics, so
  gravity is zero and no object is ever simulated.

  ## Names

  This module is the one place that decides what things in the scene are called,
  and the answers are for the caller to use: an agent's camera is
  `"<agent>.<sensor>"`, its two joints are `"<agent>.free"` and `"<agent>.pitch"`,
  and an object's geom is `"<name>_<count>"` — the count because Monty lets the
  same object stand in a scene twice.
  """

  alias Monty.Simulators.ExMujoco.Orientation

  # MuJoCo's primitives, and Habitat's names for the same shapes — kept because a
  # Habitat-era config still names an object this world can place. A sphere
  # stands in for a cone, because MuJoCo has no cone primitive.
  @primitives %{
    "box" => "box",
    "capsule" => "capsule",
    "cylinder" => "cylinder",
    "ellipsoid" => "ellipsoid",
    "sphere" => "sphere"
  }

  @habitat_primitives %{
    "capsule3DSolid" => "capsule",
    "cubeSolid" => "box",
    "cylinderSolid" => "cylinder",
    "coneSolid" => "sphere"
  }

  # Habitat's primitives are much smaller than MuJoCo's, so their scale is
  # adjusted — by trial and error, as in Monty.
  @habitat_scale [0.1, 0.1, 0.1]

  @identity_quaternion [1.0, 0.0, 0.0, 0.0]

  @typedoc """
  One object as this scene placed it: the geom MuJoCo will have, and what the
  experiment says the object is.
  """
  @type placed :: %{
          object_name: String.t(),
          geom: String.t(),
          semantic_id: integer() | nil,
          position: [float()],
          rotation: Orientation.t(),
          scale: [float()],
          shape: map(),
          params: map()
        }

  @typedoc "The scene as text, and the objects in it."
  @type built :: %{xml: String.t(), objects: [placed()]}

  @doc """
  A scene from an experiment's spec.

  The spec is `Monty.Simulators.Mujoco.Simulator.MuJoCoSimulator.new/1`'s —
  `"data_path"`, `"agents"`, `"objects"` — with string keys, because it is
  assembled from a config.
  """
  @spec build(map()) :: built()
  def build(spec) when is_map(spec) do
    agents = Map.get(spec, "agents") || []
    objects = place(spec)

    xml =
      [
        "<mujoco model=\"monty\">",
        settings(agents),
        assets(objects),
        worldbody(agents, objects),
        "</mujoco>"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    %{xml: xml, objects: objects}
  end

  @doc """
  The camera an agent's sensor looks through: `"<agent>.<sensor>"`.
  """
  @spec camera(String.t(), String.t()) :: String.t()
  def camera(agent_id, sensor_id), do: "#{agent_id}.#{sensor_id}"

  @doc "The joint that carries an agent's body: its seven `qpos` numbers."
  @spec free_joint(String.t()) :: String.t()
  def free_joint(agent_id), do: "#{agent_id}.free"

  @doc "The hinge that pitches an agent's sensor head."
  @spec pitch_joint(String.t()) :: String.t()
  def pitch_joint(agent_id), do: "#{agent_id}.pitch"

  @doc """
  The horizontal field of view at zoom 1.

  It has to stay in step with `Monty.Frameworks.EnvironmentUtils.Transforms.DepthTo3DLocations`,
  which is the transform that undoes the projection.
  """
  @spec camera_fovh() :: float()
  def camera_fovh, do: 90.0

  @doc """
  The vertical field of view for a zoom level, in degrees.

  MuJoCo's camera states a *vertical* field of view while Monty's transform undoes
  the projection with a horizontal one, so this is the conversion the two have to
  agree on.
  """
  @spec zoom_fovy(float(), pos_integer(), pos_integer(), float()) :: float()
  def zoom_fovy(base_fovh, height, width, zoom) do
    ratio = height / width
    base = :math.pi() * base_fovh / 180.0

    2.0 * :math.atan2(ratio * :math.tan(base / 2.0), zoom) * 180.0 / :math.pi()
  end

  ## The scene's own numbers

  # Gravity is zero because nothing falls here: a step is `mj_forward`, not
  # `mj_step`. The headlight is Habitat's lighting — ambient, and no diffuse, so
  # the object's back side is lit as Monty's world lights it.
  defp settings(agents) do
    {height, width} = largest_sensor(agents)

    """
      <option gravity="0 0 0"/>
      <visual>
        <global offwidth="#{width}" offheight="#{height}"/>
        <map znear="0.005" zfar="500"/>
        <headlight ambient="0.5 0.5 0.5" diffuse="0 0 0" specular="0 0 0"/>
      </visual>
    """
  end

  # The offscreen buffer is as large as the largest sensor, so every sensor's
  # image fits in it. Without sensors there is nothing to ask, and a default
  # keeps the buffer renderable.
  defp largest_sensor([]), do: {64, 64}

  defp largest_sensor(agents) do
    agents
    |> Enum.flat_map(&sensor_configs/1)
    |> Enum.reduce({64, 64}, fn {_sensor_id, config}, {tallest, widest} ->
      {max(tallest, config["height"] || 64), max(widest, config["width"] || 64)}
    end)
  end

  # Meshes, textures and materials come before the bodies that use them: MJCF
  # resolves assets first.
  defp assets(objects) do
    case for(%{shape: shape} <- objects, Map.has_key?(shape, :asset), do: shape.asset) do
      [] -> ""
      assets -> "  <asset>\n#{assets |> Enum.uniq() |> Enum.join("\n")}\n  </asset>"
    end
  end

  defp worldbody(agents, objects) do
    """
      <worldbody>
        <light pos="0 0 0.2" diffuse="0.6 0.6 0.6" specular="0.1 0.1 0.1" directional="true"/>
    #{Enum.map_join(agents, "\n", &agent/1)}
    #{Enum.map_join(objects, "\n", &geom/1)}
      </worldbody>
    """
  end

  ## Agents

  # An agent: its body, the free joint that moves it, and the sensor body hinged
  # inside it with one camera per sensor. A body that moves has to declare an
  # inertial or MuJoCo refuses to compile the model, and Monty gives both bodies
  # unit mass and unit inertia.
  defp agent(agent) do
    id = agent["agent_id"] || "agent_id_0"

    """
        <body name="#{id}" pos="#{numbers(vector(agent["position"]))}" quat="#{numbers(Tuple.to_list(quaternion(agent["rotation"])))}">
          <freejoint name="#{free_joint(id)}"/>
          <inertial pos="0 0 0" mass="1" diaginertia="1 1 1"/>
          <body name="#{id}.sensor" pos="0 0 0" quat="#{numbers(@identity_quaternion)}">
            <joint name="#{pitch_joint(id)}" type="hinge" axis="1 0 0"/>
            <inertial pos="0 0 0" mass="1" diaginertia="1 1 1"/>
    #{Enum.map_join(sensor_configs(agent), "\n", fn {sensor_id, config} -> camera_line(id, sensor_id, config) end)}
          </body>
        </body>
    """
  end

  # A camera's resolution is the renderer's business, not MuJoCo's, so only the
  # field of view is set from it.
  defp camera_line(agent_id, sensor_id, config) do
    height = config["height"] || 64
    width = config["width"] || 64
    fovy = zoom_fovy(camera_fovh(), height, width, config["zoom"] || 1.0)

    "        <camera name=\"#{camera(agent_id, sensor_id)}\" " <>
      "pos=\"#{numbers(vector(config["position"]))}\" " <>
      "quat=\"#{numbers(Tuple.to_list(quaternion(config["rotation"])))}\" fovy=\"#{number(fovy)}\"/>"
  end

  defp sensor_configs(agent), do: Map.to_list(agent["sensor_configs"] || %{})

  ## Objects

  defp place(spec) do
    data_path = Map.get(spec, "data_path")

    spec
    |> Map.get("objects")
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {object, index} -> place_object(object, index, data_path) end)
  end

  defp place_object(object, index, data_path) do
    name = object["name"]
    scale = extent(object["scale"])

    %{
      object_name: name,
      geom: "#{name}_#{index}",
      semantic_id: Map.get(object, "semantic_id"),
      position: vector(object["position"]),
      rotation: quaternion(object["rotation"]),
      scale: scale,
      shape: shape(name, scale, data_path),
      params: Map.take(object, ["euler_rotation", "quat_rotation"])
    }
  end

  defp shape(name, scale, data_path) do
    primitive(name, scale) || habitat_primitive(name, scale) || mesh(name, scale, data_path)
  end

  defp primitive(name, scale) do
    case Map.fetch(@primitives, name) do
      {:ok, type} -> %{type: type, size: scale}
      :error -> nil
    end
  end

  # A capsule uses only the first two parts of its size — the end spheres' radius
  # and the cylinder's half-length — and 0.75 is Habitat's proportion of it.
  defp habitat_primitive(name, scale) do
    case Map.fetch(@habitat_primitives, name) do
      {:ok, type} ->
        scaled = Enum.zip_with(scale, @habitat_scale, &(&1 * &2))

        %{type: type, size: capsule_size(type, scaled)}

      :error ->
        nil
    end
  end

  defp capsule_size("capsule", [radius, half_length, third]),
    do: [radius, half_length * 0.75, third]

  defp capsule_size(_type, size), do: size

  # A custom object is a mesh and its texture, loaded once per object type and
  # scale: MuJoCo stores the scale on the mesh and not on the geom, so two
  # scales are two meshes.
  defp mesh(name, scale, data_path) do
    path = object_path(data_path, name)
    metadata = metadata(Path.join(path, "metadata.json"), name)
    base = "#{name}_#{Enum.map_join(scale, "_", &number/1)}"
    texture = Path.join(path, "texture_map.png")
    object_file = Path.join(path, "textured.obj")
    mesh_scale = numbers(Enum.zip_with(scale, metadata.scale, &(&1 * &2)))
    refquat = numbers(Tuple.to_list(metadata.refquat))

    %{
      material: "#{base}_mat",
      mesh: "#{base}_mesh",
      asset:
        [
          ~s(<texture name="#{base}_tex" type="2d" file="#{texture}"/>),
          ~s(<material name="#{base}_mat" texture="#{base}_tex"/>),
          ~s(<mesh name="#{base}_mesh" file="#{object_file}" scale="#{mesh_scale}" ) <>
            ~s(refpos="#{numbers(metadata.refpos)}" refquat="#{refquat}"/>)
        ]
        |> Enum.map_join("\n", &("        " <> &1))
    }
  end

  defp geom(%{shape: %{type: type, size: size}} = object) do
    # Every primitive is turned -90° about x, because Habitat's capsule lies
    # along y where MuJoCo's points along z. Monty applies the correction to all
    # of them, not only the capsule.
    rotation = Orientation.multiply(object.rotation, Orientation.about_x(-90))
    quat = numbers(Tuple.to_list(rotation))

    ~s(    <geom name="#{object.geom}" type="#{type}" size="#{numbers(size)}" pos="#{numbers(object.position)}" quat="#{quat}"/>)
  end

  defp geom(%{shape: %{mesh: mesh, material: material}} = object) do
    quat = numbers(Tuple.to_list(object.rotation))

    ~s(    <geom name="#{object.geom}" type="mesh" mesh="#{mesh}" material="#{material}" pos="#{numbers(object.position)}" quat="#{quat}"/>)
  end

  defp object_path(nil, name) do
    raise ArgumentError,
          "a scene of custom objects needs a data path and this one has none: " <>
            "#{inspect(name)} is a mesh, and there is nowhere to read it from"
  end

  defp object_path(data_path, name) do
    path = Path.join(data_path, name)

    unless File.dir?(path) do
      raise ArgumentError, "unknown object type: #{name} is not a directory under #{data_path}"
    end

    for file <- ["texture_map.png", "textured.obj"], not File.regular?(Path.join(path, file)) do
      raise ArgumentError, "the #{name} at #{path} is missing '#{file}'"
    end

    path
  end

  # An object's `metadata.json` says where its vertices are measured from and how
  # to turn and scale them into the scene. A key nobody knows is refused rather
  # than ignored: a typo would otherwise be a scene drawn slightly wrong, silently.
  # sobelow_skip ["Traversal.FileModule"]
  # `path` is the experiment's own data directory plus an object name that
  # `object_path/2` has already resolved, and neither comes from a request.
  defp metadata(path, name) do
    case File.read(path) do
      {:error, :enoent} ->
        %{refpos: [0.0, 0.0, 0.0], refquat: Orientation.identity(), scale: [1.0, 1.0, 1.0]}

      {:ok, text} ->
        decoded = decode_metadata(text, name)
        unknown = Map.keys(decoded) -- ["refpos", "refquat", "scale"]

        if unknown != [] do
          raise ArgumentError,
                "the #{name} metadata has fields nobody knows: #{Enum.join(unknown, ", ")}"
        end

        %{
          refpos: vector(Map.get(decoded, "refpos")),
          refquat: quaternion(Map.get(decoded, "refquat")),
          scale: extent(Map.get(decoded, "scale"))
        }
    end
  end

  defp decode_metadata(text, name) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> raise ArgumentError, "the #{name} metadata could not be decoded"
    end
  end

  ## Numbers

  defp vector(nil), do: [0.0, 0.0, 0.0]
  defp vector([_, _, _] = values), do: Enum.map(values, &(&1 * 1.0))
  defp vector(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> vector()

  # A scale a config does not name is one: an object is its own size unless the
  # experiment says otherwise, where an unnamed *place* is the origin.
  defp extent(nil), do: [1.0, 1.0, 1.0]
  defp extent(values), do: vector(values)

  defp quaternion(nil), do: Orientation.identity()

  defp quaternion(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> quaternion()

  defp quaternion([_, _, _, _] = values), do: values |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()

  # An MJCF file is read by a C parser that takes as many digits as it is given,
  # so a float crosses as its shortest round-trip form rather than as Elixir's
  # inspection of it.
  defp numbers(values), do: Enum.map_join(values, " ", &number/1)

  defp number(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp number(value) when is_integer(value), do: Integer.to_string(value)
end
