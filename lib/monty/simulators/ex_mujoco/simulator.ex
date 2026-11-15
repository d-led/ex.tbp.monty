defmodule Monty.Simulators.ExMujoco.Simulator do
  @moduledoc """
  The running scene: a MuJoCo model, its data, its renderers and its agents.

  This is `ex_mujoco`'s counterpart to `priv/monty_py/world.py`'s
  `MuJoCoSimulator`. The difference is what it is made of: no interpreter, no
  JSON, and no arrays crossing a boundary — the model is compiled by a C++ NIF, an
  action writes the free joints' `qpos`, `mj_forward` computes the kinematics, and
  a render answers each sensor's images as binaries.

  ## Why a step is not a simulation step

  Monty's world calls `mj_forward`, never `mj_step`: an agent is *put* where its
  action says, and nothing in a MuJoCo experiment falls, collides or settles. So a
  step here is: write the poses the actions produced, forward, and look.

  ## What a step answers

  `observations/2` and `state/1` are MuJoCo's own shapes, exactly as
  `priv/monty_py/world.py` answers them — per agent and per sensor, `depth`,
  `rgba` and (when the sensor asks for it) `semantic`, as nested lists; and per
  agent its position, its `wxyz` rotation, and each sensor's pose relative to it.
  Both are read by `Monty.Simulators.Port.Protocol` on the way to the model, so a
  difference here is a difference in what the model is told.
  """

  alias ExMujoco.{Model, Renderer, Tensor, Types}

  alias Monty.Simulators.ExMujoco.{Agent, Scene}

  @enforce_keys [:model, :data, :agents, :semantic_ids]
  defstruct [
    :model,
    :data,
    :agents,
    :semantic_ids,
    :objects,
    :renderers,
    raise_actuate_missing: false
  ]

  @typedoc """
  A compiled scene: what draws it, what stands in it, and the id each object's
  pixels carry.
  """
  @type t :: %__MODULE__{
          model: ExMujoco.model(),
          data: ExMujoco.data(),
          agents: %{optional(String.t()) => Agent.t()},
          semantic_ids: %{optional(integer()) => integer()},
          objects: [Scene.placed()],
          renderers: %{optional({pos_integer(), pos_integer()}) => Renderer.t()},
          raise_actuate_missing: boolean()
        }

  @doc """
  Compiles the scene a spec describes, and the renderers its sensors will look
  through.

  The renderers are made here, once, because a renderer uploads the model's
  meshes and textures into OpenGL objects: one per resolution is enough, and a
  second one would upload them again.
  """
  @spec start(map()) :: t()
  def start(spec) when is_map(spec) do
    %{xml: xml, objects: objects} = Scene.build(spec)
    model = compile(xml)
    agents = agents(spec, model)

    %__MODULE__{
      model: model,
      data: ExMujoco.data(model),
      agents: agents,
      objects: objects,
      semantic_ids: semantic_ids(model, objects),
      renderers: renderers(model, agents),
      raise_actuate_missing: Map.get(spec, "raise_actuate_missing") || false
    }
  end

  defp compile(xml) do
    case ExMujoco.load_string(xml) do
      {:ok, model} ->
        model

      {:error, error} ->
        raise RuntimeError, "MuJoCo will not compile this scene: " <> Exception.message(error)
    end
  end

  defp agents(spec, model) do
    spec
    |> Map.get("agents")
    |> List.wrap()
    |> Map.new(fn agent -> build(agent, model) end)
  end

  defp build(agent, model) do
    id = agent["agent_id"] || "agent_id_0"

    %Agent{
      id: id,
      class: agent["class"] || "SurfaceAgent",
      sensors: agent["sensor_configs"] || %{},
      free: qpos_address(model, Scene.free_joint(id)),
      pitch: qpos_address(model, Scene.pitch_joint(id)),
      position: vector(agent["position"]),
      rotation: quaternion(agent["rotation"])
    }
    |> Agent.place()
    |> then(&{id, &1})
  end

  # Where a joint's numbers start in `qpos`. Read from the model rather than
  # counted, because the order joints are declared in is MuJoCo's to decide.
  defp qpos_address(model, joint) do
    id = ExMujoco.Api.mj_name2id(model, Types.Obj.joint(), joint)

    model
    |> Model.jnt_qposadr()
    |> Tensor.to_list()
    |> Enum.at(id)
  end

  # One renderer per resolution, because a renderer uploads the model's meshes
  # and textures into GL objects and a second one would upload them again.
  defp renderers(model, agents) do
    agents
    |> resolutions()
    |> Map.new(fn resolution -> {resolution, renderer_for(model, resolution)} end)
  end

  defp resolutions(agents) do
    agents
    |> Map.values()
    |> Enum.flat_map(& &1.sensors)
    |> Enum.map(fn {_sensor_id, config} -> resolution(config) end)
    |> MapSet.new()
  end

  defp renderer_for(model, {height, width}), do: Renderer.new(model, width, height)

  defp semantic_ids(model, objects) do
    geom_types = model |> Model.geom_type() |> Tensor.to_list()

    Enum.reduce(objects, %{-1 => 0}, fn object, ids ->
      geom = geom_id(model, object)

      # A scene that names no semantic id takes the one MuJoCo gives the shape —
      # which is what `priv/monty_py/world.py` does, for a config that never
      # needed a label.
      Map.put(ids, geom, object.semantic_id || Enum.at(geom_types, geom))
    end)
  end

  defp geom_id(model, object), do: ExMujoco.Api.mj_name2id(model, Types.Obj.geom(), object.geom)

  @doc """
  Puts every agent back where its episode started, then looks at what they see.
  """
  @spec reset(t()) :: {t(), map(), map()}
  def reset(simulator) do
    simulator = %{
      simulator
      | agents: Map.new(simulator.agents, fn {id, agent} -> {id, Agent.reset(agent)} end)
    }

    {simulator, observations(simulator, nil), state(simulator)}
  end

  @doc """
  Applies `actions` — Monty's encoded action maps — then answers what the agents
  see and where they are.

  `only` names the sensors to render: a positioning step reads one of them, and
  the renders and the decode of the others would be thrown away.
  """
  @spec step(t(), [map()], [String.t()] | nil) :: {t(), map(), map()}
  def step(simulator, actions, only) do
    simulator = Enum.reduce(actions, simulator, &act(&2, &1))
    simulator = forward(simulator)

    {simulator, observations(simulator, only), state(simulator)}
  end

  defp act(simulator, %{"agent_id" => id} = action) do
    agent = Map.fetch!(simulator.agents, id)
    acted = Agent.act(agent, action, simulator.raise_actuate_missing)

    %{simulator | agents: Map.put(simulator.agents, id, acted)}
  end

  @doc """
  What every sensor saw, for the sensors `only` names (`nil` for all of them).
  """
  @spec observations(t(), [String.t()] | nil) :: map()
  def observations(simulator, only) do
    Map.new(simulator.agents, fn {id, agent} ->
      {id, observations(simulator, agent, only)}
    end)
  end

  defp observations(simulator, agent, only) do
    agent.sensors
    |> Enum.filter(fn {sensor_id, _config} -> only == nil or sensor_id in only end)
    |> Map.new(fn {sensor_id, config} ->
      {sensor_id, looked_at(simulator, agent, sensor_id, config)}
    end)
  end

  # MuJoCo renders RGB only and Monty's transforms expect RGBA, so the alpha
  # channel is added here: a camera always returns opaque pixels.
  defp looked_at(simulator, agent, sensor_id, config) do
    images =
      Renderer.read(
        renderer(simulator, config),
        simulator.data,
        Scene.camera(agent.id, sensor_id),
        passes(config)
      )

    decode(passes(config), images, resolution(config), simulator.semantic_ids)
  end

  defp renderer(simulator, config), do: Map.fetch!(simulator.renderers, resolution(config))

  ## The pictures, in the shape a model reads

  @doc """
  The passes a sensor asks for: what the camera saw and how far away it was, and
  the ids of what it was looking at only when the sensor wants them.

  A third pass is a third render, so it is the scene's choice rather than a
  default.
  """
  @spec passes(map()) :: [ExMujoco.Renderer.pass()]
  def passes(config), do: [:rgb, :depth] ++ if(config["semantic"], do: [:segmentation], else: [])

  @doc """
  A sensor's own resolution, or the protocol's when it names none.

  The renderer for a resolution is made once per model, so this is also what
  picks one.
  """
  @spec resolution(map()) :: {pos_integer(), pos_integer()}
  def resolution(config), do: {config["height"] || 64, config["width"] || 64}

  @doc """
  What a renderer answered, in the shape a model reads: one pass per name, rows
  top first, `rgba` with the alpha channel the camera does not send.
  """
  @spec decode([ExMujoco.Renderer.pass()], [binary()], {pos_integer(), pos_integer()}, map()) ::
          map()
  def decode(passes, images, {_height, width}, semantic_ids) do
    Enum.zip(passes, images)
    |> Map.new(fn
      {:rgb, binary} -> {"rgba", rows(binary, width, :rgba)}
      {:depth, binary} -> {"depth", rows(binary, width, :depth)}
      {:segmentation, binary} -> {"semantic", rows(binary, width, {:semantic, semantic_ids})}
    end)
  end

  # Segmentation answers a geom id per pixel; what a model reads is the semantic
  # id the object was added with. The background is the one id every scene maps —
  # MuJoCo says -1 where Habitat and Monty say 0.
  @doc "One pass's bytes, chunked into the rows a model walks."
  @spec rows(binary(), pos_integer(), :rgba | :depth | {:semantic, map()}) :: [[term()]]
  def rows(binary, width, {:semantic, mapping}) do
    for(<<id::signed-32-little <- binary>>, do: Map.get(mapping, id, id))
    |> Enum.chunk_every(width)
  end

  def rows(binary, width, :rgba) do
    for(<<red::8, green::8, blue::8 <- binary>>, do: [red, green, blue, 255])
    |> Enum.chunk_every(width)
  end

  def rows(binary, width, :depth) do
    for(<<value::float-32-little <- binary>>, do: value)
    |> Enum.chunk_every(width)
  end

  ## Where the agents are

  @doc """
  Every agent's place, and each sensor's pose relative to it.
  """
  @spec state(t()) :: map()
  def state(simulator) do
    Map.new(simulator.agents, fn {id, agent} ->
      {id,
       %{
         "position" => agent.position,
         "rotation" => Tuple.to_list(agent.rotation),
         "sensors" => Agent.sensor_poses(agent)
       }}
    end)
  end

  @doc """
  The object an episode is about: the first this scene holds, and how it is placed.

  Monty's `PrimaryTarget` carries the object's name, its semantic id, and every
  parameter the object init sampler produced — a supervised experiment states its
  `euler_rotation` and `quat_rotation` there — so those travel with it.
  """
  @spec primary_target(t()) :: map() | nil
  def primary_target(%__MODULE__{objects: []}), do: nil

  def primary_target(%__MODULE__{objects: [object | _rest]} = simulator) do
    %{
      "object_name" => object.object_name,
      "semantic_id" => Map.fetch!(simulator.semantic_ids, geom_id(simulator.model, object)),
      "position" => object.position,
      "rotation" => Tuple.to_list(object.rotation),
      "scale" => object.scale
    }
    |> Map.merge(object.params)
  end

  @doc """
  Which object each semantic id is, for a log that wants to name what was seen.
  """
  @spec semantic_id_to_label(t()) :: %{optional(integer()) => String.t()}
  def semantic_id_to_label(simulator) do
    Map.new(simulator.objects, fn object ->
      {Map.fetch!(simulator.semantic_ids, geom_id(simulator.model, object)), object.object_name}
    end)
  end

  ## The bodies' state

  # Every action has been applied to the agents; this is the one place their poses
  # become MuJoCo's state.
  defp forward(simulator) do
    qpos =
      simulator.data
      |> ExMujoco.state(Types.State.qpos())
      |> decode_floats()
      |> then(fn qpos -> Enum.reduce(Map.values(simulator.agents), qpos, &pose(&2, &1)) end)

    :ok = ExMujoco.put_state(simulator.data, Types.State.qpos(), encode_floats(qpos))
    :ok = ExMujoco.forward(simulator.data)

    simulator
  end

  defp pose(qpos, agent) do
    {free, seven, pitch, one} = Agent.qpos(agent)

    qpos
    |> replace_at(free, seven)
    |> replace_at(pitch, one)
  end

  defp replace_at(list, at, values) do
    {head, tail} = Enum.split(list, at)

    head ++ values ++ Enum.drop(tail, length(values))
  end

  # MuJoCo's `mjtNum` is a float64 in this machine's own byte order: `get_state`
  # hands over the memory as it is, and `set_state` reads back what it is given.
  defp decode_floats(binary), do: for(<<value::float-64-little <- binary>>, do: value)

  defp encode_floats(values), do: for(value <- values, into: <<>>, do: <<value::float-64-little>>)

  defp quaternion(nil), do: {1.0, 0.0, 0.0, 0.0}
  defp quaternion(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> quaternion()
  defp quaternion([_, _, _, _] = values), do: values |> vector() |> List.to_tuple()

  defp vector(nil), do: [0.0, 0.0, 0.0]
  defp vector(values), do: Enum.map(values, &(&1 * 1.0))
end
