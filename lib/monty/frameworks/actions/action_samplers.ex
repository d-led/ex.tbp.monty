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

  @doc """
  The sampler a config describes.

      action_sampler:
        _target_: tbp.monty.frameworks.actions.action_samplers.ConstantSampler
        actions:
        - ${monty.class:tbp.monty.frameworks.actions.actions.MoveForward}
        translation_distance: 0.004

  The actions are named as classes too, so they resolve the same way the
  sampler itself does. A parameter the sampler does not have is an error: the
  config asked for behaviour this port cannot give, and answering something
  else would make the run a different experiment.
  """
  @spec from_config(map()) :: Monty.Frameworks.Actions.ActionSamplers.ActionSampler.t()
  def from_config(%{"_target_" => _target} = config) do
    options =
      config
      |> Map.delete("_target_")
      |> Enum.map(&sampler_option/1)

    Monty.Config.Target.class!(config).new(options)
  end

  # Every parameter Monty's two samplers take, by the name it has in a config.
  @sampler_keys %{
    "absolute_degrees" => :absolute_degrees,
    "direction" => :direction,
    "location" => :location,
    "rotation_degrees" => :rotation_degrees,
    "translation_distance" => :translation_distance,
    "min_absolute_degrees" => :min_absolute_degrees,
    "max_absolute_degrees" => :max_absolute_degrees,
    "min_rotation_degrees" => :min_rotation_degrees,
    "max_rotation_degrees" => :max_rotation_degrees,
    "min_translation" => :min_translation,
    "max_translation" => :max_translation
  }

  defp sampler_option({"actions", actions}),
    do: {:actions, Enum.map(actions, &Monty.Config.Target.class!/1)}

  defp sampler_option({"rotation_quat", quaternion}),
    do: {:rotation_quat, List.to_tuple(quaternion)}

  defp sampler_option({key, value}) do
    case Map.fetch(@sampler_keys, key) do
      {:ok, option} -> {option, value}
      :error -> raise ArgumentError, "a sampler takes no #{inspect(key)}"
    end
  end
end
