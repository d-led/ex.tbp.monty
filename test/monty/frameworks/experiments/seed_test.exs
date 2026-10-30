defmodule Monty.Frameworks.Experiments.SeedTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Experiments.Seed

  describe "episode_seed/3" do
    # The three numbers are Monty's, read from the `episode_seed` column of a
    # `base_config_10distinctobj_dist_agent` evaluation run: ten episodes, seed
    # 42. They are the fixtures that say this derivation is Monty's and not one
    # that merely looks like it.
    test "is the seed Monty gave the first three episodes of its own run" do
      assert Seed.episode_seed(42, :eval, 0) == 1_170_100_843
      assert Seed.episode_seed(42, :eval, 1) == 1_680_878_960
      assert Seed.episode_seed(42, :eval, 2) == 2_497_867_848
    end

    test "gives an episode a different seed from the episode before it" do
      seeds = Enum.map(0..9, &Seed.episode_seed(42, :eval, &1))

      assert seeds == Enum.uniq(seeds)
    end

    test "separates training from evaluation, so the same episode is not the same draw" do
      refute Seed.episode_seed(42, :train, 0) == Seed.episode_seed(42, :eval, 0)
    end

    test "is the same every time, because a run has to be repeatable" do
      assert Seed.episode_seed(7, :eval, 3) == Seed.episode_seed(7, :eval, 3)
    end

    test "stays inside the 32 bits NumPy seeds a RandomState with" do
      for episode <- [0, 1, 5, 1_000] do
        assert Seed.episode_seed(42, :eval, episode) < 4_294_967_296
      end
    end
  end
end
