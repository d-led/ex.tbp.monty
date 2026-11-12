defmodule Monty.Simulators.Mujoco.Simulator.MuJoCoSimulator do
  @moduledoc """
  Monty's `MuJoCoSimulator`: the world a MuJoCo experiment steps.

  ## Why the code looks nothing like Python's

  This class is ported, not missing — and it is not a transliteration either.
  Monty's version is a Python object holding a `MjSpec`, a set of lights and one
  renderer per resolution, and it answers the experiment through the containers
  of the `tbp` package (`Observations`, `AgentState`, `Rotation`). None of those
  containers exist here, and the ones that matter — the spec, the renderers, the
  agents' cameras — belong to a C library with a Python binding, so they cannot
  be Elixir either.

  So the scene lives where it has to: `priv/monty_py/world.py` is this
  project's own script, written against `mujoco`, `numpy` and
  `numpy-quaternion`, that builds the spec, drops the renderers when the model
  changes, loads a mesh per object with its semantic id, and answers plain dicts
  — because the BEAM reads JSON, not Monty's classes. It is not the file
  `simulator.py` with a different extension: it is the same behaviour written
  for an interpreter that is embedded rather than imported.
  `Monty.Simulators.Mujoco.Host` runs it inside the interpreter this application
  carries (`pythonx`), and this module is the value a run threads: it builds the
  scene from the experiment's own config, hands the motor system's actions
  across, and answers what Monty's agents saw.

  What stayed Monty's is the part that decides the numbers: the shape of the
  spec, which renderer looks through which camera, how a mesh and its semantic
  id enter the scene, the `observations` / `states` / `step` / `reset` / `close`
  surface, the agents' `actuate_*` methods, metres, `wxyz` rotations, and the
  order of the operations. A run that reads differently from Monty's is a bug in
  this file, not a difference of language.

  ## What it is not

  It is not the *experiment*: Monty's `MontyExperiment`, its environment
  interface and its positioning procedures are the port's own runtime
  (`Monty.Runtime.*`, `Monty.Studio.Run`), and the transforms between what a
  camera rendered and what a sensor module is given are this port's
  (`Monty.Frameworks.EnvironmentUtils.Transforms`).

  ## Positioning

  `positions_itself?/0` is false: the agent starts where the config puts it and
  is moved by the actions the motor system chose, through Monty's own
  `actuate_*` methods. Monty's interface would run its `pre_episode` procedures
  in Python; here they are the port's, over the same world.
  """

  @behaviour Monty.Simulators.Environment

  alias Monty.Frameworks.Actions.ActionJSONEncoder
  alias Monty.Simulators.Mujoco.Host
  alias Monty.Simulators.Port.Protocol

  defstruct id: nil,
            spec: %{},
            sensors: [],
            started?: false,
            primary_target: nil,
            semantic_id_to_label: %{}

  @typedoc """
  One run's world: the scene it was built from, the handle the host knows it by,
  and what its last episode was about.
  """
  @type t :: %__MODULE__{
          id: String.t() | nil,
          spec: map(),
          sensors: [Monty.Simulators.Environment.sensor_id()],
          started?: boolean(),
          primary_target: map() | nil,
          semantic_id_to_label: %{optional(integer()) => String.t()}
        }

  @doc """
  A world from the experiment's own numbers.

  Options: `:data_path` — where the object meshes are; `:agents` — each agent's
  class, id, pose and sensor configs, as Monty's `env_init_args` states them;
  `:objects` — what stands in the scene; `:sensors` — the sensor ids a step
  reports.

  Nothing is started here: a run builds a world it may never step, and the
  interpreter only has to work when it does.
  """
  @impl true
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      id: "world-#{System.unique_integer([:positive])}",
      spec: %{
        "data_path" => Keyword.get(options, :data_path),
        "agents" => Keyword.get(options, :agents, []),
        "objects" => Keyword.get(options, :objects, []),
        "raise_actuate_missing" => Keyword.get(options, :raise_actuate_missing, false)
      },
      sensors: Keyword.get(options, :sensors, [])
    }
  end

  @doc """
  Observations and proprioceptive state after `actions`.

  Keys and units are Monty's, because they are Monty's arrays: metres, `wxyz`
  rotations, and the images his cameras rendered.
  """
  @impl true
  @spec step(t(), [Monty.Frameworks.Actions.Action.t()]) :: {map(), map(), t()}
  def step(%__MODULE__{} = world, actions), do: step(world, actions, nil)

  @doc """
  Observations and proprioceptive state after `actions`, rendering only `sensors`.

  `nil` renders every sensor in the scene, which is what a model's step asks for.
  A positioning step names the one sensor its procedure reads: the other one's
  three renders cross the port and are decoded to be thrown away.
  """
  @spec step(t(), [Monty.Frameworks.Actions.Action.t()], [String.t()] | nil) ::
          {map(), map(), t()}
  def step(%__MODULE__{} = world, actions, sensors) do
    world = start(world)
    encoded = Enum.map(actions, &ActionJSONEncoder.encode/1)

    case Host.step(world.id, encoded, sensors) do
      {:ok, answer} ->
        {answer["observations"], Protocol.proprioceptive_state(answer["proprioceptive_state"]),
         world}

      {:error, reason} ->
        raise RuntimeError, reason
    end
  end

  @doc """
  The first step of an episode, and what that episode is about.

  Monty's interface picks the object and tells the model what it is; here the
  scene was built from the config, so the answer is what this world holds.
  """
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = world) do
    world = start(world)

    case Host.reset(world.id) do
      {:ok, answer} ->
        %{
          world
          | primary_target: answer["primary_target"],
            semantic_id_to_label: labels(answer["semantic_id_to_label"])
        }

      {:error, reason} ->
        raise RuntimeError, reason
    end
  end

  @impl true
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{id: nil}), do: :ok

  def stop(%__MODULE__{} = world) do
    Host.stop_world(world.id)
  end

  @impl true
  # This world steps what the actions say and never moves an agent on its own:
  # Monty's `SetAgentPose` has nothing to set here.
  @spec positions_itself?() :: false
  def positions_itself?, do: false

  @impl true
  def primary_target(%__MODULE__{primary_target: target}), do: target

  @impl true
  def semantic_id_to_label(%__MODULE__{semantic_id_to_label: labels}), do: labels

  defp start(%__MODULE__{started?: true} = world), do: world

  defp start(%__MODULE__{} = world) do
    case Host.start_world(world.id, world.spec) do
      :ok -> %{world | started?: true}
      {:error, reason} -> raise RuntimeError, reason
    end
  end

  # A semantic id is an integer on this side (Monty's `SemanticID`), a string key
  # once it has been through JSON.
  defp labels(nil), do: %{}
  defp labels(labels), do: Map.new(labels, fn {id, label} -> {String.to_integer(id), label} end)
end
