defmodule Monty.Experiment.Environment.Interface do
  @moduledoc """
  The layer between a world and everything above it.

  Mirrors `tbp/monty/experiment/environment.py::Interface`: it steps the
  environment, then runs the experiment's transform chain over the observations
  before any module sees them, and hands the agent's pose back untouched. The
  order matters — a transform may read the previous one's output — and Monty's
  constructor *resets*, which runs the chain as well.

  ## Why this is not just a helper

  Monty's experiment talks to the world only through this: `run_episode_steps`,
  `pre_episode` and every hook above them take an interface, not a simulator. A
  port that stepped its world in two places — once for positioning, once for the
  episode — would be one edit away from the two disagreeing about what a step is.
  Both go through `step/2` here.

  ## What is recorded of it

  `scripts/record_monty_interface.py` ran Monty's own interface with a stub world
  and two tagging transforms and wrote down the sequence: which transform ran,
  what it saw, and that it was handed a stream and a pose. There is no arithmetic
  in this module to compare — the record is the *order*, and the test asserts it.

  ## The world is a value

  Monty's environment is mutated by `step` and `reset`; here a step answers the
  world it leaves behind, as everywhere else in this port. Resetting therefore
  needs to be told how to make a fresh world: `:reset` is a function that answers
  one, and the default is the world the interface was built with. A reset then
  looks at the fresh world the way Monty's does, by taking the no-action step the
  episode's first step would have taken anyway.
  """

  alias Monty.Frameworks.EnvironmentUtils.Transforms

  @enforce_keys [:env]
  defstruct env: nil, reset: nil, transforms: [], ctx: nil, seed: 0, mode: :eval

  @typedoc "A world, how to make a fresh one, and what to do to its observations."
  @type t :: %__MODULE__{
          env: term(),
          reset: (-> term()) | nil,
          transforms: [struct()],
          ctx: Monty.Context.t() | nil,
          seed: integer(),
          mode: :train | :eval
        }

  @doc """
  An interface over `:env`.

  Options: `:transforms` (the experiment's chain, in order), `:reset` (a function
  answering a fresh world), `:seed` and `:mode`.

  Monty's constructor resets the environment; this one does not, because the world
  it is given is already the episode's starting world — `reset/1` is there for the
  next episode.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    seed = Keyword.get(options, :seed, 0)

    %__MODULE__{
      env: Keyword.fetch!(options, :env),
      reset: Keyword.get(options, :reset),
      transforms: Keyword.get(options, :transforms, []),
      ctx: Keyword.get_lazy(options, :ctx, fn -> Monty.Context.new(seed) end),
      seed: seed,
      mode: Keyword.get(options, :mode, :eval)
    }
  end

  @doc """
  Steps the world with `actions` and transforms what came back.

  The pose the world answered is *not* transformed: transforms change what the
  sensors see, not where the agent is.
  """
  @spec step(t(), [Monty.Frameworks.Actions.Action.t()]) :: {map(), map(), t()}
  def step(%__MODULE__{} = interface, actions) do
    {observations, proprioceptive_state, env} = step_world(interface.env, actions)

    {apply_transforms(interface, observations, proprioceptive_state), proprioceptive_state,
     %{interface | env: env}}
  end

  @doc """
  A fresh world, and what it shows before anything is asked of it.

  Monty's `Interface.reset`: the environment is reset and its observations are
  transformed before they are handed back.
  """
  @spec reset(t()) :: {map(), map(), t()}
  def reset(%__MODULE__{} = interface) do
    interface = %{interface | env: fresh(interface)}
    step(interface, [])
  end

  @doc "Monty's `pre_episode`: an episode starts from a reset."
  @spec pre_episode(t()) :: {map(), map(), t()}
  def pre_episode(%__MODULE__{} = interface), do: reset(interface)

  @doc "Monty's `post_episode`, `pre_epoch` and `post_epoch` do nothing."
  @spec post_episode(t()) :: t()
  def post_episode(%__MODULE__{} = interface), do: interface

  @doc false
  @spec apply_transforms(t(), map(), map()) :: map()
  def apply_transforms(%__MODULE__{} = interface, observations, proprioceptive_state) do
    Transforms.run(interface.transforms, observations, interface.ctx, proprioceptive_state)
  end

  # The stand-in world steps with a function; a world behind a port answers with
  # its own process. Both answer `{observations, pose, world}`.
  defp step_world(env, actions) when is_function(env, 1) do
    {observations, proprioceptive_state} = env.(actions)
    {observations, proprioceptive_state, env}
  end

  defp step_world(env, actions), do: env.__struct__.step(env, actions)

  defp fresh(%__MODULE__{reset: nil} = interface), do: interface.env
  defp fresh(%__MODULE__{reset: reset}), do: reset.()
end
