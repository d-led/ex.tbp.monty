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

  Monty passes `ctx.rng` into every `sample` call and spends it in place. Here
  that stream is `Monty.Random.Stream`, one process a model, reached as
  `ctx.rng`: a sampler asks it for the numbers it needs, so the choice an action
  rests on is numpy's and it is spent in the episode's order. `ActionSampler.sample/3`
  reads the stream off the context; nothing is threaded back.
  """

  @doc """
  One of the first `count` non-negative integers, each equally likely.

  Monty's `rng.choice(count)`, which is numpy's masked `randint` and not
  `floor(uniform * count)`: for a count that is not a power of two the two
  disagree, and a walk drawn from the wrong one is a different walk.
  """
  @spec choose(Monty.Random.Stream.server(), pos_integer()) :: non_neg_integer()
  def choose(stream, count), do: Monty.Random.Stream.choice(stream, count)

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
