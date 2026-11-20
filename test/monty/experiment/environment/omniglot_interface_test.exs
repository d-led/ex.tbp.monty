defmodule Monty.Experiment.Environment.OmniglotInterfaceTest do
  # What a config's alphabets, characters and versions mean for an Omniglot run:
  # one episode per character, in order, wrapping at the end, each character named
  # by its alphabet and its number. Monty's class
  # (`experiment/environment.py::OmniglotInterface`) is the source of all three
  # rules.
  #
  # The first case translates Monty's `test_omniglot_data_loader`
  # (`tests/integration/frameworks/environments/embodied_data_test.py`), which
  # drives the interface with `[0, 0, 0, 1, 1, 1]` x `[1, 2, 3, 1, 2, 3]` and
  # asserts the first name and the count. Monty's world there is a fake with three
  # alphabet names and no data; this one is a real world over two alphabets of one
  # character each, so a switch can be seen to have loaded the character and not
  # only counted it.

  use ExUnit.Case, async: true

  alias Monty.Experiment.Environment.OmniglotInterface
  alias Monty.Frameworks.Environments.TwoDData.OmniglotEnvironment

  setup do
    path = OmniglotFixture.write(["Alpha", "Beta"])
    on_exit(fn -> File.rm_rf(path) end)

    world = OmniglotEnvironment.new(data_path: path, patch_size: 10)

    interface =
      OmniglotInterface.new(
        alphabets: [0, 0, 0, 1, 1, 1],
        characters: [1, 2, 3, 1, 2, 3],
        versions: [1, 1, 1, 1, 1, 1],
        object_names: world.alphabet_names
      )

    {:ok, interface: interface, world: world}
  end

  test "a config's characters are named by their alphabet and their number, one episode each",
       %{interface: interface} do
    assert interface.object_names == [
             "Alpha_1",
             "Alpha_2",
             "Alpha_3",
             "Beta_1",
             "Beta_2",
             "Beta_3"
           ]

    assert interface.n_objects == 6
  end

  test "the character at an index is taken as the episode's target and loaded",
       %{interface: interface, world: world} do
    assert {:ok, interface, world} =
             OmniglotInterface.change_object_by_idx(interface, 3, world)

    assert %{alphabet: "Beta", character_id: 1, character_version: 1} = world
    assert interface.primary_target["object_name"] == "Beta_1"
    assert interface.primary_target["position"] == [0.0, 0.0, 0.0]
  end

  test "the next episode is the next character, and past the last it starts again",
       %{interface: interface, world: world} do
    {:ok, last, world} = OmniglotInterface.change_object_by_idx(interface, 5, world)

    assert {:ok, wrapped, world} = OmniglotInterface.post_episode(last, world)

    assert %{alphabet: "Alpha", character_id: 1} = world
    assert wrapped.primary_target["object_name"] == "Alpha_1"
    assert wrapped.episodes == 1
  end

  test "an index outside the characters is refused with Monty's words",
       %{interface: interface, world: world} do
    assert {:error, message} = OmniglotInterface.change_object_by_idx(interface, 6, world)
    assert message == "idx must satisfy 0 <= idx < 6, got 6"
  end
end
