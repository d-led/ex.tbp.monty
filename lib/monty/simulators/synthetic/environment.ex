defmodule Monty.Simulators.Synthetic.Environment do
  @moduledoc """
  A stand-in world for developing the runtime, driven by the actions it is given.

  Monty's world is a Python process; until that bridge runs here
  (`docs/simulator-port.md`), the runtime needs something deterministic to step.
  This one moves a single agent according to the actions the motor system chose —
  see `Monty.Simulators.Synthetic.Kinematics` for which actions it honours and
  the conventions it follows — and answers the two payloads Monty's
  `Interface.step/1` returns: observations per agent and sensor, and the
  proprioceptive state in global coordinates.

  It has **no geometry**: nothing is out there, so an observation is what the
  sensor's own pose says, and the only feature is a value that follows the
  agent's x. That is enough for the runtime and for the pages that watch it, and
  it is worth being plain about what it is not: a run against this world says
  nothing about a learned object, while a run against a simulator says
  everything.

  It is a simulator, not a ported module: nothing here claims to mirror a Python
  file.
  """

  @behaviour Monty.Simulators.Environment

  alias Monty.Frameworks.Models.MotorSystemState.{AgentState, SensorState}
  alias Monty.Simulators.Synthetic.{Kinematics, Scene}

  @agent_id "agent_id_0"
  @default_sensor "patch"

  @enforce_keys [:sensor_ids, :world]
  defstruct [:sensor_ids, :world, scene: nil, views: %{}, agent: nil, sensors: %{}]

  @type t :: %__MODULE__{
          sensor_ids: [Monty.Simulators.Environment.sensor_id()],
          world: Kinematics.t(),
          scene: Scene.t() | nil,
          views: %{optional(Monty.Simulators.Environment.sensor_id()) => keyword()},
          agent: Kinematics.pose() | nil,
          sensors: %{optional(Monty.Simulators.Environment.sensor_id()) => Kinematics.pose()}
        }

  @impl true
  @spec new([Monty.Simulators.Environment.sensor_id()]) :: t()
  def new(sensor_ids), do: new(sensor_ids, nil)

  @doc """
  A world looking at `scene`, each sensor through its own camera.

  `:views` is a camera per sensor, keyed by sensor id, in the terms
  `Monty.Simulators.Synthetic.Scene.render/3` takes — a resolution, a zoom and a
  field of view. A sensor with no camera renders one ray down its own axis.
  `:agent` and `:sensors` are where the episode starts, as an experiment's
  simulator is configured.

  Geometry is a choice, not an assumption: with a scene the world renders depth,
  colour and semantic id for every sensor, which is what a ported surface policy
  steers by; without one it reports only where the sensors are, and a percept
  built from it says its pose is undefined.
  """
  @spec new([Monty.Simulators.Environment.sensor_id()], Scene.t() | nil, keyword()) :: t()
  def new(sensor_ids, scene, options \\ []) do
    sensor_ids = if sensor_ids == [], do: [@default_sensor], else: sensor_ids
    agent = Keyword.get(options, :agent)
    sensors = Keyword.get(options, :sensors, %{})

    %__MODULE__{
      sensor_ids: sensor_ids,
      world: Kinematics.new(sensor_ids, agent: agent, sensors: sensors),
      scene: scene,
      views: Map.new(Keyword.get(options, :views, %{})),
      agent: agent,
      # Kept so that a reset starts the episode where this one began, rather
      # than wherever the last one ended.
      sensors: sensors
    }
  end

  @doc """
  Observations and proprioceptive state after `actions`.

  Keys and units follow Monty: metres, sensor positions in the world, the
  agent's pose absolute, each sensor's pose relative to the agent.
  """
  @impl true
  @spec step(t(), [Monty.Frameworks.Actions.Action.t()]) :: {map(), map(), t()}
  def step(%__MODULE__{} = environment, actions) do
    world = Kinematics.step(environment.world, actions)

    {observations(environment, world), proprioceptive_state(world), %{environment | world: world}}
  end

  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = environment) do
    new(environment.sensor_ids, environment.scene,
      views: environment.views,
      agent: environment.agent,
      sensors: environment.sensors
    )
  end

  @doc "How the runtime addresses this environment's parts in a module spec."
  @spec agent_id() :: String.t()
  def agent_id, do: @agent_id

  defp observations(environment, world) do
    [x, _y, _z] = world.agent.position

    %{
      @agent_id =>
        Map.new(Kinematics.sensor_world_poses(world), fn {sensor_id, pose} ->
          {sensor_id,
           Map.merge(
             %{"location" => pose.position, "value" => x},
             features(environment.scene, pose, camera(environment, sensor_id))
           )}
        end)
    }
  end

  defp camera(environment, sensor_id), do: Map.get(environment.views, sensor_id, [])

  # A world with no scene can say nothing about a surface, so it says nothing.
  defp features(nil, _pose, _view), do: %{}

  defp features(scene, pose, view), do: features(Scene.render(scene, pose, view))

  # What a sensor sees, in the shape Monty's worlds answer in: images of depth,
  # colour and semantic id, and nothing else. Monty's own code indexes these
  # (`PositioningProcedure.depth_at_center` reads the centre pixel), so a world
  # that answered a bare number would make any policy that looks at the image
  # fail on this world and work on Monty's.
  #
  # A ray that missed answers depth 0, which is what Monty's depth images use for
  # "no return", and an experiment's `MissingToMaxDepth` transform is what turns
  # that into the furthest the sensor can see (`docs/monty-bugs.md` §1.7).
  #
  # The surface — its normal and its curvatures — is *not* answered here. A camera
  # reports an image, and a sensor module estimates the surface from it
  # (`Monty.Frameworks.Utils.SensorProcessing`); a world that also told the sensor
  # what the answer was would hide every mistake in that estimate.
  defp features(rendered) do
    %{
      "depth" => rendered.depth,
      "rgba" => rendered.rgba,
      "semantic" => rendered.semantic
    }
  end

  # Monty's worlds answer with `AgentState`/`SensorState`, and its motor system
  # reads them as such, so that is the shape this one answers in too: a world
  # that answered a different shape would make the body depend on which world it
  # was given. The agent's pose is absolute, each sensor's is relative to it.
  defp proprioceptive_state(world) do
    %{
      @agent_id => %AgentState{
        position: world.agent.position,
        rotation: world.agent.rotation,
        sensors:
          Map.new(Kinematics.sensor_poses(world), fn {sensor_id, sensor} ->
            {sensor_id, %SensorState{position: sensor.position, rotation: sensor.rotation}}
          end)
      }
    }
  end
end
