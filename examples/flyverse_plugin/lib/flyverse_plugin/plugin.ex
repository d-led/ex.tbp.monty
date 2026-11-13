defmodule FlyversePlugin.Plugin do
  @moduledoc """
  What one plugin in this node answers, and how it is asked.

  `MontyPlugin` owns the wire: `describe/0`, and the four requests a caller makes
  of a provider. This module is the process's side of that — the shape
  `FlyversePlugin.Offer` dispatches on, so a plugin module says what it does and
  the process says how it is reached.

  ## Why `new/2` and `call/3` take the process's state

  A motor policy here steps a NIF resource, and a resource cannot be sent to
  another node. So the simulation lives in the process offering the plugin, the
  policy value that travels carries only its name, and every callback is handed
  that state to read and answer. A plugin that decided with nothing but its
  struct would implement the same callbacks and ignore the second argument —
  which is what `FlyversePlugin.Experiment` does, because a definition is data.

  `run/0` is the experiment's one question and is optional: a plugin that is not
  a definition has no run to offer.
  """

  @doc "What a cluster asks about it, in `MontyPlugin`'s shape."
  @callback describe() :: MontyPlugin.description()

  @doc "The state this plugin's process starts with."
  @callback initial_state() :: map()

  @doc "A policy, and the state that now holds its simulation."
  @callback new(options :: keyword(), state :: map()) ::
              {:ok, policy :: term(), state :: map()} | {:error, String.t()}

  @doc """
  One step: the five arguments `MotorPolicy.call/6` receives after the policy,
  the policy as it now stands, and the state it was stepped with.
  """
  @callback call(
              policy :: term(),
              {ctx :: term(), observations :: map() | nil, motor_state :: term(),
               percept :: term(), goal :: term()},
              state :: map()
            ) :: {:ok, result :: term(), policy :: term(), state :: map()} | {:error, String.t()}

  @doc "Starts the next episode."
  @callback reset(policy :: term(), state :: map()) ::
              {:ok, policy :: term(), state :: map()} | {:error, String.t()}

  @doc "What the policy recorded, for a run that wants to be read afterwards."
  @callback state_dict(policy :: term(), state :: map()) :: map()

  @doc "The run this plugin asks for, as data."
  @callback run() :: map()

  @optional_callbacks new: 2, call: 3, reset: 2, state_dict: 2, run: 0
end
