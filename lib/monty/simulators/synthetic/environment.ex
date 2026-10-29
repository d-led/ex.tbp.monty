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

  alias Monty.Geometry.Rotation
  alias Monty.Simulators.Synthetic.Kinematics

  @agent_id "agent_id_0"
  @default_sensor "patch"

  @enforce_keys [:sensor_ids, :world]
  defstruct [:sensor_ids, :world]

  @type t :: %__MODULE__{
          sensor_ids: [Monty.Simulators.Environment.sensor_id()],
          world: Kinematics.t()
        }

  @impl true
  @spec new([Monty.Simulators.Environment.sensor_id()]) :: t()
  def new(sensor_ids) do
    sensor_ids = if sensor_ids == [], do: [@default_sensor], else: sensor_ids
    %__MODULE__{sensor_ids: sensor_ids, world: Kinematics.new(sensor_ids)}
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

    {observations(world), proprioceptive_state(world), %{environment | world: world}}
  end

  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = environment), do: new(environment.sensor_ids)

  @doc "How the runtime addresses this environment's parts in a module spec."
  @spec agent_id() :: String.t()
  def agent_id, do: @agent_id

  defp observations(world) do
    [x, _y, _z] = world.agent.position

    %{
      @agent_id =>
        Map.new(Kinematics.sensor_positions(world), fn {sensor_id, position} ->
          {sensor_id, %{"location" => position, "value" => x}}
        end)
    }
  end

  defp proprioceptive_state(world) do
    %{
      @agent_id => %{
        "position" => world.agent.position,
        "rotation" => Rotation.to_xyzw(world.agent.rotation),
        "sensors" =>
          Map.new(Kinematics.sensor_poses(world), fn {sensor_id, sensor} ->
            {sensor_id,
             %{"position" => sensor.position, "rotation" => Rotation.to_xyzw(sensor.rotation)}}
          end)
      }
    }
  end
end
