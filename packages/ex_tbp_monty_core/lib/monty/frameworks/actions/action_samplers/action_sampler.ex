defmodule Monty.Frameworks.Actions.ActionSamplers.ActionSampler do
  @moduledoc """
  The shared part of a sampler: which actions it can make, and how to ask.

  Mirrors `tbp/monty/frameworks/actions/action_samplers.py::ActionSampler`.
  Monty's base class keeps the list of action types and, in `sample`, picks one
  at random and calls its own `sample_<name>`; everything else lives in the
  samplers built on it, which is why this module holds only those two calls.

  A sampler here is a struct with an `:actions` list of the action modules it
  can make — `Monty.Frameworks.Actions.LookDown` and friends — and the fourteen
  `sample_<name>/3` functions that the pick dispatches to. The struct's own
  module is what gets called, so this works for any sampler that keeps that
  list, without a behaviour to satisfy.

  ## The stream is the episode's

  Monty writes `self.action_sampler.sample(self.agent_id, ctx.rng)` and spends
  the episode's one mutable `RandomState` in place. Here that stream is
  `Monty.Random.Stream`, reached as `ctx.rng`, and `sample/3` takes the context
  so the stream is read where Monty reads it. A policy therefore holds no
  stream at all, and a second call in the same step draws the next number:
  several draws a step arrive in Monty's order because the stream advances
  itself (`docs/monty-differences.md` §2.5).
  """

  alias Monty.Context
  alias Monty.Frameworks.Actions.ActionSamplers

  @typedoc """
  Any struct with an `:actions` list, answered by a module with the
  `sample_<name>/3` functions this module dispatches to.
  """
  @type t :: %{required(:actions) => [module()], optional(atom()) => term()}

  @doc """
  One randomly chosen action, from the episode's stream.

  The choice is uniform over the configured actions — including over repeats,
  as numpy's `rng.choice` is, so a list naming an action twice makes it twice as
  likely.
  """
  @spec sample(t(), atom() | String.t(), Context.t()) :: Monty.Frameworks.Actions.Action.t()
  def sample(%{actions: actions, __struct__: module} = sampler, agent_id, %Context{} = ctx)
      when is_list(actions) and actions != [] do
    stream = Context.rng(ctx)
    index = ActionSamplers.choose(stream, length(actions))
    action_name = actions |> Enum.at(index) |> then(& &1.name())

    # Monty builds this name with an f-string and `getattr`. Every sampler
    # defines all fourteen, so the atom always exists already — which is worth
    # saying rather than minting one from a string.
    sample_function = String.to_existing_atom("sample_#{action_name}")

    apply(module, sample_function, [sampler, agent_id, stream])
  end
end
