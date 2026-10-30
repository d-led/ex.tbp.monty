defmodule Monty.Frameworks.Experiments.Seed do
  @moduledoc """
  The seed one episode runs on.

  Mirrors `tbp/monty/frameworks/experiments/seed.py`. An experiment has one seed
  and every episode derives its own from it, so that the same experiment always
  presents the same object in the same place on the same step, while two
  episodes of it do not draw the same random numbers. Monty's reason for the
  second half is the one that matters: seeding every episode alike would put
  every object at the same rotation.

  The derivation is a hash rather than arithmetic — `sha256("{seed}-{mode}-{episode}")`
  read as an integer and taken modulo 2³² — which is why this is ported rather
  than invented: the numbers an episode runs on are part of the experiment's
  observable behaviour, and a run only reproduces Monty's if it starts from
  Monty's seed.
  """

  @episode_seeds 4_294_967_296

  @doc """
  The seed episode number `episode` of a `seed`-seeded experiment runs on.

  Counting starts at zero: the first episode of an evaluation epoch is episode
  `0`, as `eval_episodes` is when Monty's `pre_episode` reseeds.
  """
  @spec episode_seed(integer(), :train | :eval, non_neg_integer()) :: non_neg_integer()
  def episode_seed(seed, mode, episode) do
    :crypto.hash(:sha256, "#{seed}-#{mode}-#{episode}")
    |> :binary.decode_unsigned()
    |> rem(@episode_seeds)
  end
end
