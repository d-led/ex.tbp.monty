defmodule Monty.Frameworks.Actions.ActionSamplers do
  @moduledoc """
  Making actions from a random stream: the choices a policy draws.

  Mirrors `tbp/monty/frameworks/actions/action_samplers.py`, which holds three
  names:

    * `...ActionSamplers.ActionSampler` — **ported**: the base, which picks one
      of its configured actions and asks its own `sample_<name>` for it;
    * `...ActionSamplers.ConstantSampler` — **ported**: fixed parameters, so
      every action of a kind is identical;
    * `...ActionSamplers.UniformlyDistributedSampler` — **ported**: parameters
      drawn uniformly from configured ranges.

  ## How the random stream reaches a sampler

  Monty passes a mutable `RandomState` into every `sample` call and mutates it
  in place, so consecutive draws consume one advancing stream across the whole
  episode. Elixir has no mutable stream, so a sampler answers the state it
  leaves behind and the caller threads it:

      {action, rng} = ActionSampler.sample(sampler, agent_id, rng)

  Threading rather than rederiving the stream from the step is the decision of
  `docs/monty-bugs.md` §2.5, and it is forced by behaviour rather than chosen
  on cost: a policy draws several times in one step, and a stream keyed to the
  step alone would answer those draws identically. `ActionSampler.stream/3` is
  where the thread begins for a policy that has none yet.
  `scripts/bench_samplers.exs` records what the threading saves.
  """

  @doc """
  A float drawn uniformly from `[low, high)`.

  Monty's `rng.uniform(low=..., high=...)`.
  """
  @spec uniform(:rand.state(), float(), float()) :: {float(), :rand.state()}
  def uniform(state, low, high) do
    {draw, state} = :rand.uniform_s(state)
    {low + (high - low) * draw, state}
  end

  @doc """
  One of the first `count` non-negative integers, each equally likely.
  """
  @spec choose(:rand.state(), pos_integer()) :: {non_neg_integer(), :rand.state()}
  def choose(state, count) do
    {draw, state} = :rand.uniform_s(state)
    {min(trunc(draw * count), count - 1), state}
  end

  @doc """
  Three floats drawn uniformly from `[0, 1)`, as numpy's `rng.random(3)`.

  Three separate draws rather than one, because that is what the stream order
  then is, and a quaternion built from them must consume the stream in Monty's
  order for the sampler to be recognisable.
  """
  @spec three(:rand.state()) :: {[float()], :rand.state()}
  def three(state) do
    {a, state} = :rand.uniform_s(state)
    {b, state} = :rand.uniform_s(state)
    {c, state} = :rand.uniform_s(state)

    {[a, b, c], state}
  end
end
