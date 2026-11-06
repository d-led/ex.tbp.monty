defmodule Monty.Frameworks.Environments.ObjectInitSamplersTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Environments.ObjectInitSamplers.{Default, Predefined, RandomRotation}

  @seed 42

  # Monty's own numbers: `np.random.RandomState(episode_seed(42, "train", n))`,
  # three uniform draws from [0, 360) and then one from [-0.5, 0.5).
  @angles_episode_0 [261.48627178189327, 311.87404004901305, 6.389211691425238]
  @angles_episode_1 [270.93897985666723, 69.65792538542384, 320.74640068870195]

  describe "the poses a config wrote down" do
    test "an epoch turns the object, and the third epoch is the first again" do
      sampler = Predefined.new()

      assert euler(sampler, 0) == [0.0, 0.0, 0.0]
      assert euler(sampler, 1) == [45.0, 0.0, 0.0]
      assert euler(sampler, 2) == [0.0, 0.0, 0.0]
    end

    test "the object stands where the config put it" do
      params =
        Predefined.new(positions: [[0.0, 1.5, 0.0]]) |> Predefined.call(@seed, :train, 0, 0)

      assert params["position"] == [0.0, 1.5, 0.0]
    end

    test "a sampler asked to change every episode counts episodes, not epochs" do
      sampler = Predefined.new(change_every_episode: true)

      assert euler(sampler, 0, 0) == [0.0, 0.0, 0.0]
      assert euler(sampler, 0, 1) == [45.0, 0.0, 0.0]
      assert euler(sampler, 3, 1) == [45.0, 0.0, 0.0]
    end

    test "the quaternion is the rotation the angles name" do
      params = Predefined.new() |> Predefined.call(@seed, :train, 1, 0)

      assert params["euler_rotation"] == [45.0, 0.0, 0.0]
      # Half of 45°: the w term of a rotation by 45° about x, and its x term.
      assert_in_delta Enum.at(params["rotation"], 0), :math.cos(:math.pi() / 8), 1.0e-12
      assert_in_delta Enum.at(params["rotation"], 1), :math.sin(:math.pi() / 8), 1.0e-12
    end

    test "the poses it walks are every rotation, scale and place it was given" do
      sampler =
        Predefined.new(
          rotations: [[0.0, 0.0, 0.0], [45.0, 0.0, 0.0]],
          scales: [[1.0, 1.0, 1.0], [2.0, 2.0, 2.0]]
        )

      assert Predefined.size(sampler) == 4
      assert length(Predefined.all_combinations_of_params(sampler)) == 4

      assert [
               %{
                 rotations: [[0.0, 0.0, 0.0]],
                 scales: [[1.0, 1.0, 1.0]],
                 positions: [[0.0, 1.5, 0.0]]
               }
               | _
             ] =
               Predefined.all_combinations_of_params(sampler)
    end
  end

  describe "an orientation drawn per episode" do
    test "the angles are numpy's for the episode's seed" do
      assert_close(drawn_angles(0), @angles_episode_0)
      assert_close(drawn_angles(1), @angles_episode_1)
    end

    test "two episodes of one run are turned differently" do
      refute drawn_angles(0) == drawn_angles(1)
    end

    test "the same episode is the same pose again" do
      assert drawn_angles(2) == drawn_angles(2)
    end

    test "the place is the sampler's, and a default sampler draws its own" do
      assert (RandomRotation.new() |> RandomRotation.call(@seed, :train, 0, 7))["position"] ==
               [0.0, 1.5, 0.0]

      assert_in_delta hd(Default.call(@seed, :train, 0, 0)["position"]),
                      -0.03615826063315675,
                      1.0e-12
    end
  end

  defp drawn_angles(episode),
    do:
      RandomRotation.new()
      |> RandomRotation.call(@seed, :train, 0, episode)
      |> Map.fetch!("euler_rotation")

  defp euler(%Predefined{} = sampler, epoch, episode \\ 0),
    do: sampler |> Predefined.call(@seed, :train, epoch, episode) |> Map.fetch!("euler_rotation")

  defp assert_close(actual, expected) do
    actual
    |> Enum.zip(expected)
    |> Enum.each(fn {got, want} -> assert_in_delta got, want, 1.0e-9 end)
  end
end
