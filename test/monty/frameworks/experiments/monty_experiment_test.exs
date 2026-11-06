defmodule Monty.Frameworks.Experiments.MontyExperimentTest do
  @moduledoc """
  Monty's episode loop, over a step that is not a model.

  The state is a counter and the report is the count, so what the tests can say
  is what the loop is answerable for: when it stops, how many steps the episode
  took, and what a step that could not be taken becomes.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Experiments.MontyExperiment

  defp episode(options \\ []) do
    Map.merge(
      %{
        step: fn count -> {:ok, count + 1, count + 1} end,
        finished?: fn count -> count >= 3 end,
        stopped?: fn -> false end
      },
      Map.new(options)
    )
  end

  test "steps until the experiment's policy says the episode is over" do
    assert {:finished, [3, 2, 1], 3} = MontyExperiment.run_episode_steps(0, episode())
  end

  test "a stop lands between steps, not inside one" do
    assert {:stopped, [], 0} =
             MontyExperiment.run_episode_steps(0, episode(stopped?: fn -> true end))
  end

  test "a step that could not be taken ends the episode with the steps that were" do
    dies_after_two = %{
      episode()
      | step: fn
          count when count < 2 -> {:ok, count + 1, count + 1}
          _count -> {:error, :module_died}
        end
    }

    assert {{:crashed, 2, :module_died}, [2, 1], 2} =
             MontyExperiment.run_episode_steps(0, dies_after_two)
  end

  test "an episode that finishes on its first step takes one step" do
    assert {:finished, [1], 1} =
             MontyExperiment.run_episode_steps(0, episode(finished?: fn count -> count >= 1 end))
  end

  describe "an epoch" do
    test "is one episode per object, in the order the experiment names them" do
      callbacks = epoch(%{objects: ["mug", "bowl"]})

      assert {:finished, [%{object: "mug"}, %{object: "bowl"}], _state} =
               MontyExperiment.run_epoch(%{}, callbacks)

      assert Enum.map(
               elem(MontyExperiment.run_epoch(%{}, callbacks), 1),
               & &1.object
             ) == ["mug", "bowl"]
    end

    test "numbers its episodes from where the epoch is told to start" do
      assert {:finished, [%{episode: 77}, %{episode: 78}], _} =
               MontyExperiment.run_epoch(
                 %{},
                 epoch(%{objects: ["mug", "bowl"], first_episode: 77})
               )
    end

    test "says what each episode did: which object, how many steps, how it ended" do
      assert {:finished, [mug, bowl], _} =
               MontyExperiment.run_epoch(%{}, epoch(%{objects: ["mug", "bowl"]}))

      assert mug == %{object: "mug", episode: 0, outcome: :finished, steps: 3}
      assert bowl == %{object: "bowl", episode: 1, outcome: :finished, steps: 3}
    end

    test "tells an episode which epoch of the phase it belongs to" do
      # The epoch is what a config's sampler turns the object on, so it has to
      # reach the episode: it travels in the callbacks the hook is given, and a
      # run of three epochs over two objects sees each of them three times.
      callbacks =
        epoch(%{
          objects: ["mug", "bowl"],
          epochs: 3,
          pre_episode: fn _state, _index, _object, callbacks ->
            send(self(), {:epoch, Map.get(callbacks, :epoch)})
            {:ok, 0}
          end
        })

      assert {:finished, _, _} = MontyExperiment.run_epochs(%{}, callbacks)

      assert epochs_seen() == [0, 0, 1, 1, 2, 2]
    end

    test "is an episode the caller stopped, and no more objects after it" do
      callbacks = epoch(%{objects: ["mug", "bowl"], stopped?: fn -> true end})

      assert {:stopped, [], _} = MontyExperiment.run_epoch(%{}, callbacks)
    end

    test "ends at the object whose episode could not begin, and names it" do
      callbacks =
        epoch(%{
          objects: ["mug", "bowl"],
          pre_episode: fn
            state, 0, "mug", _callbacks -> {:ok, state}
            _state, _index, _object, _callbacks -> {:error, :object_not_visible}
          end
        })

      assert {{:crashed, 0, :object_not_visible}, [mug, bowl], _} =
               MontyExperiment.run_epoch(%{}, callbacks)

      assert %{object: "bowl", steps: 0, outcome: {:crashed, 0, :object_not_visible}} = bowl
      assert %{object: "mug", outcome: :finished} = mug
    end
  end

  describe "several epochs" do
    test "walk the object list again, numbering every episode of the run" do
      callbacks = epoch(%{objects: ["mug", "bowl"], epochs: 2})

      assert {:finished, episodes, _} = MontyExperiment.run_epochs(%{}, callbacks)
      assert Enum.map(episodes, & &1.episode) == [0, 1, 2, 3]
      assert Enum.map(episodes, & &1.object) == ["mug", "bowl", "mug", "bowl"]
    end

    test "stop after the episode budget, rather than at the end of an epoch" do
      callbacks = epoch(%{objects: ["mug", "bowl"], epochs: 3, episodes: 3})

      assert {:finished, episodes, _} = MontyExperiment.run_epochs(%{}, callbacks)
      assert length(episodes) == 3
      assert Enum.map(episodes, & &1.object) == ["mug", "bowl", "mug"]
    end

    test "are one epoch when the config names none, rather than none at all" do
      assert {:finished, [_, _], _} =
               MontyExperiment.run_epochs(%{}, epoch(%{objects: ["mug", "bowl"], epochs: 0}))
    end

    test "end at the first epoch a caller stops" do
      assert {:stopped, [], _} =
               MontyExperiment.run_epochs(
                 0,
                 epoch(%{objects: ["mug"], epochs: 3, stopped?: fn -> true end})
               )
    end
  end

  # The epochs the episodes were told they belong to, in the order they were
  # started.
  defp epochs_seen do
    receive do
      {:epoch, epoch} -> [epoch | epochs_seen()]
    after
      0 -> []
    end
  end

  defp epoch(options) do
    Map.merge(
      Map.merge(
        %{
          objects: ["mug"],
          epochs: 1,
          # Every episode starts where Monty's does: a fresh count in a fresh
          # world, which is what the studio's `pre_episode` gives it.
          pre_episode: fn _state, _index, _object, _callbacks -> {:ok, 0} end,
          post_episode: fn state, _outcome, _infos -> state end
        },
        episode()
      ),
      Map.new(options)
    )
  end
end
