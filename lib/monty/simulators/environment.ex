defmodule Monty.Simulators.Environment do
  @moduledoc """
  What a world has to be: something a step can be taken against.

  This is the Elixir side of Monty's `Interface.step/1`, which hands the model
  the actions it chose on the previous step and answers
  `{observations, proprioceptive_state}`. Everything that is *not* the world —
  the model, the body, the policies, the learning modules — is written against
  this and does not know which world it is talking to.

  Two implementations:

    * `Monty.Simulators.Synthetic.Environment` — a stand-in with kinematics and
      no geometry, implementing this behaviour: its state is the struct, so a
      run carries the world around with it;
    * `Monty.Simulators.Port.Environment` — a simulator process on the other side
      of a port (MuJoCo, Habitat, later a camera). Its state is a *process*, so
      it is used where a world is a function — `Monty.Runtime.Episode` takes one
      — rather than as a value.

  An environment that keeps its state in a value answers with itself, as every
  step in this port does, so a caller threads it and does not care whether the
  world behind it is a map or a process.
  """

  alias Monty.Frameworks.Actions.Action

  @typedoc """
  Whatever an implementation needs to remember between steps.
  """
  @type t :: struct() | map()

  @typedoc """
  What an experiment addresses a sensor by: Monty's own configs name them as
  strings (`"patch"`), while a module spec built in Elixir may use an atom.
  """
  @type sensor_id :: atom() | String.t()

  @doc """
  A world, from what the experiment knows to build one.

  Monty's `Interface` is configured with the agent and its sensors, and reports
  every sensor it was given on every step, so a world that renders a scene is
  built from that list rather than discovering sensors as it goes. A world that
  is a simulator behind a port takes more than the sensors — an experiment name
  picks the scene — so what a world is built from is its own to say.
  """
  @callback new(what :: term()) :: t()

  @doc "The world after `actions`, with what the sensors now see."
  @callback step(t(), [Action.t()]) :: {observations :: map(), proprioceptive_state :: map(), t()}

  @doc "The world a fresh episode starts in."
  @callback reset(t()) :: t()

  @doc """
  Closes the world, if it is something that can be closed.

  A world kept in a value has nothing behind it. A world that is a simulator
  process does — a peer that outlives its run is a process nobody will ask about
  again — so it answers `stop/1`, and a run stops its world the same way it stops
  its model.
  """
  @callback stop(t()) :: :ok

  @doc """
  Whether the world starts an episode already positioned.

  Monty positions an episode in `Interface.pre_episode`: the experiment's
  procedures step the world until the target is in view, drawing from the
  episode's random stream. Which side of the port runs them is not symmetric. A
  world that is Monty's own runs Monty's `pre_episode` in Monty's environment,
  with Monty's random stream, and gets the answer Monty would get; a world that is
  a scene here has to be walked by the ported procedures.

  The world says which it is, so that a run positions exactly once: positioning a
  placed agent again would make the episode a different one from the episode
  Monty ran.
  """
  @callback positions_itself?() :: boolean()

  @optional_callbacks stop: 1, positions_itself?: 0

  @spec stop(t()) :: :ok
  def stop(env) do
    if function_exported?(env.__struct__, :stop, 1),
      do: env.__struct__.stop(env),
      else: :ok
  end

  @spec positions_itself?(t()) :: boolean()
  def positions_itself?(env) do
    function_exported?(env.__struct__, :positions_itself?, 0) and
      env.__struct__.positions_itself?()
  end
end
