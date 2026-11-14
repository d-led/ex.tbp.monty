defmodule Monty.Simulators.ExMujoco.World do
  @moduledoc """
  Monty's MuJoCo world, compiled by `ex_mujoco` instead of driven by Python.

  The same scene, the same agents, the same cameras, the same images — and no
  interpreter. `Monty.Simulators.Mujoco.Simulator.MuJoCoSimulator` steps
  `priv/monty_py/world.py` inside the Python this application carries; this walks
  the same scene through MuJoCo's C API, through `ex_mujoco`'s NIF, and answers
  the same two payloads. A run cannot tell the difference, which is the point: the
  world is a choice in the header of an experiment, not a different experiment.

  ## What is the same, on purpose

  `Monty.Simulators.ExMujoco.Scene` builds the scene from the config's own
  numbers; `Monty.Simulators.ExMujoco.Agent` answers the action vocabulary in
  MuJoCo's units and Monty's signs; `Monty.Simulators.ExMujoco.Simulator` renders
  through MuJoCo's own renderer and answers Monty's observation shape. Both worlds
  read the *same* action maps (`ActionJSONEncoder`'s), so an action cannot mean
  two things in two places.

  ## Positioning

  `positions_itself?/0` is false, as it is for the Python world: the agent starts
  where the config puts it and is moved by the actions the motor system chose,
  through Monty's own `actuate_*` answers.

  ## When it cannot render

  A machine with no OpenGL context steps this world and dies at the first image,
  because that is what the sensor modules need. `Monty.Simulators.ExMujoco.available?/0`
  answers before an experiment is opened, and `unavailable_reason/0` says why in
  words — the setup refuses a run rather than failing inside it.
  """

  @behaviour Monty.Simulators.Environment

  alias Monty.Frameworks.Actions.ActionJSONEncoder
  alias Monty.Simulators.ExMujoco.Simulator
  alias Monty.Simulators.Port.Protocol

  defstruct id: nil,
            spec: %{},
            sensors: [],
            started?: false,
            primary_target: nil,
            semantic_id_to_label: %{},
            simulator: nil

  @typedoc """
  One run's world: the scene it was built from, the simulation once it is
  compiled, and what its last episode was about.
  """
  @type t :: %__MODULE__{
          id: String.t() | nil,
          spec: map(),
          sensors: [Monty.Simulators.Environment.sensor_id()],
          started?: boolean(),
          primary_target: map() | nil,
          semantic_id_to_label: %{optional(integer()) => String.t()},
          simulator: Simulator.t() | nil
        }

  @doc """
  Whether this machine can render the images a MuJoCo experiment needs.

  The question is asked before a run is opened, so a node without OpenGL refuses
  the experiment instead of failing at its first step.
  """
  @spec available?() :: boolean()
  def available?, do: ExMujoco.Renderer.available?()

  @doc """
  Why this machine cannot render, in words — empty when it can.
  """
  @spec unavailable_reason() :: String.t()
  def unavailable_reason, do: ExMujoco.Renderer.unavailable_reason()

  @doc """
  A world from the experiment's own numbers.

  Options are `Monty.Simulators.Mujoco.Simulator.MuJoCoSimulator.new/1`'s, so the
  two worlds are built by the same call: `:data_path` — where the object meshes
  are; `:agents` — each agent's class, id, pose and sensor configs, as Monty's
  `env_init_args` states them; `:objects` — what stands in the scene; `:sensors` —
  the sensor ids a step reports.

  Nothing is compiled here: a run builds a world it may never step, and MuJoCo is
  only needed when it does.
  """
  @impl true
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      id: "ex-mujoco-world-#{System.unique_integer([:positive])}",
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

  Keys and units are Monty's, because they are Monty's numbers: metres, `wxyz`
  rotations, and the images his cameras rendered.
  """
  @impl true
  @spec step(t(), [Monty.Frameworks.Actions.Action.t()]) :: {map(), map(), t()}
  def step(%__MODULE__{} = world, actions), do: step(world, actions, nil)

  @doc """
  Observations and proprioceptive state after `actions`, rendering only `sensors`.

  `nil` renders every sensor in the scene, which is what a model's step asks for.
  A positioning step names the one sensor its procedure reads: the other one's
  renders would be drawn, decoded and thrown away.
  """
  @spec step(t(), [Monty.Frameworks.Actions.Action.t()], [String.t()] | nil) ::
          {map(), map(), t()}
  def step(%__MODULE__{} = world, actions, sensors) do
    world = start(world)
    encoded = Enum.map(actions, &ActionJSONEncoder.encode/1)

    {simulator, observations, state} = Simulator.step(world.simulator, encoded, sensors)

    {observations, Protocol.proprioceptive_state(state), %{world | simulator: simulator}}
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
    {simulator, _observations, _state} = Simulator.reset(world.simulator)

    %{
      world
      | simulator: simulator,
        primary_target: Simulator.primary_target(simulator),
        semantic_id_to_label: Simulator.semantic_id_to_label(simulator)
    }
  end

  @impl true
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{simulator: nil}), do: :ok

  # A simulator is a compiled model and the resources that draw it, and both are
  # released by the garbage collector: nothing is left behind to close.
  def stop(%__MODULE__{} = _world), do: :ok

  @impl true
  # This world steps what the actions say and never moves an agent on its own:
  # Monty's `SetAgentPose` has nothing to set until a policy emits one.
  @spec positions_itself?() :: false
  def positions_itself?, do: false

  @impl true
  def primary_target(%__MODULE__{primary_target: target}), do: target

  @impl true
  def semantic_id_to_label(%__MODULE__{semantic_id_to_label: labels}), do: labels

  defp start(%__MODULE__{started?: true} = world), do: world

  defp start(%__MODULE__{} = world) do
    %{world | started?: true, simulator: Simulator.start(world.spec)}
  end
end
