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
  A world for the sensors an experiment has.

  Monty's `Interface` is configured with the agent and its sensors, and reports
  every sensor it was given on every step, so an environment is built from that
  list rather than discovering sensors as it goes.
  """
  @callback new(sensor_ids :: [sensor_id()]) :: t()

  @doc "The world after `actions`, with what the sensors now see."
  @callback step(t(), [Action.t()]) :: {observations :: map(), proprioceptive_state :: map(), t()}

  @doc "The world a fresh episode starts in."
  @callback reset(t()) :: t()
end
