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

  ## The stream is threaded, not looked up

  Monty writes `self.action_sampler.sample(self.agent_id, ctx.rng)` and mutates
  `ctx.rng` in place, so consecutive draws consume one advancing stream. Elixir
  has no mutable state, so `sample/3` answers `{action, rng}` and the caller
  threads it. `stream/3` is where that thread starts: a policy that has none
  yet takes one from the context.

  Answering the stream rather than reseeding it from the step is not a matter
  of taste — a policy draws several times in a single step (`SurfacePolicy`
  samples a direction, then a distance), and a per-step stream would answer
  those draws with the same action every time. Neither is it a matter of cost:
  see `scripts/bench_samplers.exs`. See `docs/monty-bugs.md` §2.5 for the
  deviation this leaves and §2.1 for the streams themselves.
  """

  alias Monty.Context
  alias Monty.Frameworks.Actions.ActionSamplers

  @typedoc """
  Any struct with an `:actions` list, answered by a module with the
  `sample_<name>/3` functions this module dispatches to.
  """
  @type t :: %{required(:actions) => [module()], optional(atom()) => term()}

  @doc """
  One randomly chosen action, and the random stream after it.

  The choice is uniform over the configured actions — including over repeats,
  as numpy's `rng.choice` is, so a list naming an action twice makes it twice as
  likely.
  """
  @spec sample(t(), atom() | String.t(), :rand.state()) ::
          {Monty.Frameworks.Actions.Action.t(), :rand.state()}
  def sample(%{actions: actions, __struct__: module} = sampler, agent_id, rng)
      when is_list(actions) and actions != [] do
    {index, rng} = ActionSamplers.choose(rng, length(actions))
    action_name = actions |> Enum.at(index) |> then(& &1.name())

    # Monty builds this name with an f-string and `getattr`. Every sampler
    # defines all fourteen, so the atom always exists already — which is worth
    # saying rather than minting one from a string.
    sample_function = String.to_existing_atom("sample_#{action_name}")

    apply(module, sample_function, [sampler, agent_id, rng])
  end

  @doc """
  The stream to draw from: the one being threaded, or a new one from `ctx`.

  A policy holds the stream it is threading; before its first draw it holds
  `nil` and derives one here, from the episode seed, its own module and the
  step. The sampler's module is what names the stream, so two kinds of sampler
  working in the same step do not draw from the same one, and two samplers of
  one kind deliberately do.
  """
  @spec stream(t(), :rand.state() | nil, Context.t()) :: :rand.state()
  def stream(%{__struct__: module}, nil, %Context{} = ctx),
    do: Context.rng_for(ctx, module)

  def stream(%{}, rng, %Context{}), do: rng
end
