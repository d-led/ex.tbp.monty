defmodule Monty.Random.StreamTest do
  use ExUnit.Case, async: true

  alias Monty.Random.Stream

  # Monty's own normals for this seed, from `Monty.Random.NumpyTest`: a stream is
  # that generator behind a process, so it has to answer the same numbers and
  # hand the state on in the order it was asked.
  @episode_seed 1_170_100_843
  @normals [-0.03260111614826397, -0.046248668844803296, -0.08595771088332692]

  describe "drawing" do
    test "answers numpy's numbers, because it is numpy's generator behind a process" do
      stream = start_stream(@episode_seed)

      assert Stream.normals(stream, 3, 0.0, 0.05) == @normals
    end

    test "carries on where the last draw left off, so two draws are not one draw twice" do
      stream = start_stream(@episode_seed)

      first = Stream.random(stream)
      second = Stream.random(stream)

      refute first == second
    end

    test "gives a uniform draw inside the interval it was asked for" do
      stream = start_stream(@episode_seed)

      for _draw <- 1..50 do
        drawn = Stream.uniform(stream, -180.0, 180.0)
        assert drawn >= -180.0 and drawn < 180.0
      end
    end
  end

  describe "reseeding" do
    test "starts the episode over, which is what a new episode means" do
      stream = start_stream(@episode_seed)

      _spent = Stream.random(stream)
      assert :ok = Stream.reseed(stream, @episode_seed)

      assert Stream.normals(stream, 3, 0.0, 0.05) == @normals
    end

    test "is how another episode draws other numbers from another seed" do
      stream = start_stream(@episode_seed)
      first_episode = Stream.random(stream)

      :ok = Stream.reseed(stream, @episode_seed + 1)

      refute Stream.random(stream) == first_episode
    end
  end

  defp start_stream(seed) do
    model_id = "stream-test-#{System.unique_integer([:positive])}"

    start_supervised!({Stream, %{model_id: model_id, seed: seed}}, id: model_id)

    Stream.via(model_id)
  end
end
