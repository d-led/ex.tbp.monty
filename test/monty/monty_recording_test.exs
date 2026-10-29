defmodule Monty.MontyRecordingTest do
  @moduledoc """
  The recording of Monty's ten-episode evaluation, read back.

  `test/fixtures/monty_dist_agent_10episodes.jsonl` is one Monty run of
  `base_config_10distinctobj_dist_agent` over the ten YCB objects — the material
  the episode-level comparison is built on. These are the two facts anybody
  reading it needs before comparing anything: how the stream splits into
  episodes, and what each episode concluded.

  The replay itself is `scripts/probe_dist_agent_episodes.exs`, which prints
  Monty's conclusion beside the port's. It is not asserted here, because the two
  do not agree yet.
  """

  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Test.MontyRecording

  @recording "test/fixtures/monty_dist_agent_10episodes.jsonl"

  describe "the episodes in the recording" do
    test "are ten, one per object, split where the episode counter restarts" do
      episodes = MontyRecording.episodes!(@recording)

      assert length(episodes) == 10
      assert Enum.map(episodes, &length/1) == [43, 27, 28, 27, 36, 28, 40, 43, 35, 31]

      # A step is the percepts the module was given on it — a cortical messaging
      # protocol message, not a fixture-specific shape.
      [first_episode | _rest] = episodes
      assert [%Message{} | _more] = hd(first_episode)
    end

    test "each of them concluded on the object it was shown" do
      conclusions = MontyRecording.episode_conclusions!(@recording)

      assert Enum.map(conclusions, & &1["terminal_state"]) == List.duplicate("match", 10)

      assert Enum.map(conclusions, & &1["detected_object"]) ==
               ~w(mug bowl potted_meat_can spoon strawberry mustard_bottle dice golf_ball
                  c_lego_duplo banana)
    end
  end
end
