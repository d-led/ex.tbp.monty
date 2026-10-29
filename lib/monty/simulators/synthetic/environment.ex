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
  defstruct [:sensor_ids, :world, scene: nil]

  @type t :: %__MODULE__{
          sensor_ids: [Monty.Simulators.Environment.sensor_id()],
          world: Kinematics.t(),
          scene: Scene.t() | nil
        }

  @impl true
  @spec new([Monty.Simulators.Environment.sensor_id()]) :: t()
  def new(sensor_ids), do: new(sensor_ids, nil)

  @doc """
  A world looking at `scene`.

  Geometry is a choice, not an assumption: with a scene the world reports depth,
  a surface normal and principal curvatures for every sensor, which is what a
  ported surface policy steers by; without one it reports only where the sensors
  are, and a percept built from it says its pose is undefined.
  """
  @spec new([Monty.Simulators.Environment.sensor_id()], Scene.t() | nil) :: t()
  def new(sensor_ids, scene) do
    sensor_ids = if sensor_ids == [], do: [@default_sensor], else: sensor_ids
    %__MODULE__{sensor_ids: sensor_ids, world: Kinematics.new(sensor_ids), scene: scene}
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
  def reset(%__MODULE__{} = environment), do: new(environment.sensor_ids, environment.scene)

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
             features(environment.scene, pose)
           )}
        end)
    }
  end

  # A world with no scene can say nothing about a surface, so it says nothing.
  defp features(nil, _pose), do: %{}

  defp features(scene, pose), do: features(Scene.observe(scene, pose))

  # A one-pixel sensor sees one depth, and it is the nearest, the mean and the
  # only one at once. Monty's surface sensor reports all three; so does this.
  defp features(observation) do
    %{
      "on_object" => observation.on_object,
      "depth" => observation.depth,
      "mean_depth" => observation.depth,
      "min_depth" => observation.depth,
      "object_coverage" => if(observation.on_object, do: 1.0, else: 0.0),
      "principal_curvatures" => observation.principal_curvatures,
      "pose_vectors" => pose_vectors(observation.pose_vectors),
      "rgba" => observation.rgba
    }
  end

  # Observations are logged and stored with the run, so the three vectors travel
  # as lists: a tuple would be a scene's convenience leaking into a record.
  defp pose_vectors(nil), do: nil
  defp pose_vectors({normal, direction_1, direction_2}), do: [normal, direction_1, direction_2]

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
