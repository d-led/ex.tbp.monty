defmodule Monty.Experiment.Environment.OneObjectPerEpisodeInterfaceTest do
  @moduledoc """
  The interface numbers the objects of an experiment the way Monty does.

  `scripts/record_monty_interface_objects.py` ran Monty's own
  `OneObjectPerEpisodeInterface` against a stub scene that recorded what it was
  asked to add and remove, over three shapes of `object_names`. These replay them:
  the semantic mapping in both directions, which object comes next, the scene
  calls that makes, and the two ways it refuses an index.

  ## What is not compared

  Which distractors appear is drawn from Monty's stream, and this port draws from
  its own (`docs/monty-bugs.md` §2.1), so the *choice* is not comparable — the
  candidates are, and they are Monty's rule. Nor does the stand-in world hold more
  than one object yet, so a config asking for distractors is refused rather than
  silently run without them.
  """

  use ExUnit.Case, async: true

  alias Monty.Experiment.Environment.OneObjectPerEpisodeInterface
  alias Monty.RecordingScene

  @fixture Path.expand("../../../fixtures/monty_interface_objects.json", __DIR__)

  setup_all do
    {:ok, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "the semantic mapping is Monty's for every shape of object list", %{fixture: fixture} do
    for {shape, expected} <- fixture["shapes"] do
      interface = start(recorded(shape), fixture)

      assert interface.semantic_label_to_id == expected["semantic_label_to_id"], shape

      assert interface.semantic_id_to_label == labels_by_id(expected["semantic_id_to_label"]),
             shape

      assert interface.object_names == expected["object_names"], shape
      assert interface.source_object_list == expected["source_object_list"], shape
      assert interface.num_distractors == expected["num_distractors"], shape
      assert interface.n_objects == expected["n_objects"], shape
    end
  end

  test "it asks the scene for the object Monty would, with Monty's id", %{fixture: fixture} do
    %{
      "second object" => %{
        "calls" => calls,
        "primary_target" => target,
        "current_object" => index
      }
    } =
      fixture

    interface = start(recorded("a plain list"), fixture)

    {:ok, interface, scene} =
      OneObjectPerEpisodeInterface.change_object_by_idx(interface, 1, %RecordingScene{})

    assert scene.calls == calls
    assert interface.primary_target == target
    assert interface.current_object == index
    assert OneObjectPerEpisodeInterface.target_semantic_id(interface) == target["semantic_id"]
    assert OneObjectPerEpisodeInterface.object_name(interface) == target["object"]
  end

  test "an episode moves on to the next object, and past the end starts again", %{
    fixture: fixture
  } do
    %{"cycled" => %{"current_object" => next, "primary_target" => target}, "wrapped" => wrapped} =
      fixture

    interface = start(recorded("a plain list"), fixture)

    {:ok, interface, _scene} =
      OneObjectPerEpisodeInterface.change_object_by_idx(interface, 1, %RecordingScene{})

    {:ok, interface, _scene} =
      OneObjectPerEpisodeInterface.cycle_object(interface, %RecordingScene{})

    assert interface.current_object == next
    assert interface.primary_target == target

    {:ok, interface, _scene} =
      OneObjectPerEpisodeInterface.cycle_object(interface, %RecordingScene{})

    assert interface.current_object == wrapped["current_object"]
  end

  test "an index outside the list is refused with Monty's own message", %{fixture: fixture} do
    refusals = fixture["refusals"]

    interface = start(recorded("a plain list"), fixture)

    for {index, %{"message" => message}} <- refusals do
      assert OneObjectPerEpisodeInterface.change_object_by_idx(
               interface,
               String.to_integer(index),
               %RecordingScene{}
             ) == {:error, message}
    end
  end

  test "a distractor may be any object but the target", %{fixture: fixture} do
    interface = start(recorded("a mapping with distractors"), fixture)

    assert OneObjectPerEpisodeInterface.distractor_candidates(interface, "cone") == [
             "sphere",
             "cube",
             "cylinder"
           ]

    assert OneObjectPerEpisodeInterface.distractor_candidates(interface, "cylinder") == [
             "cone",
             "sphere",
             "cube"
           ]
  end

  test "an episode with no object yet has no target id", %{fixture: fixture} do
    interface = start(["cone"], fixture)

    assert OneObjectPerEpisodeInterface.target_semantic_id(interface) == nil

    {:ok, interface, _scene} =
      OneObjectPerEpisodeInterface.change_object_by_idx(interface, 0, %RecordingScene{})

    assert OneObjectPerEpisodeInterface.target_semantic_id(interface) == 1
  end

  test "a scene that cannot hold distractors is refused, not run without them", %{
    fixture: fixture
  } do
    interface = start(recorded("a mapping with distractors"), fixture)

    assert OneObjectPerEpisodeInterface.change_object_by_idx(interface, 0, %RecordingScene{}) ==
             {:error, {:distractors_not_supported, 2}}
  end

  # -- the recording ---------------------------------------------------------

  defp start(object_names, fixture) do
    OneObjectPerEpisodeInterface.new(
      object_names: object_names,
      object_init_sampler: fn _seed, _mode, _epochs, _episodes -> fixture["object_params"] end
    )
  end

  # The `object_names` each recorded shape was configured with, keyed by the
  # sentence the recorder used — three shapes, because Monty reads three.
  defp recorded("a list with a repeated name"), do: ["cone", "sphere", "cone", "cube"]
  defp recorded("a plain list"), do: ["cone", "sphere", "cube"]

  defp recorded("a mapping with distractors") do
    %{
      "targets_list" => ["cone", "sphere"],
      "source_object_list" => ["cone", "sphere", "cube", "cylinder"],
      "num_distractors" => 2
    }
  end

  # A recording of a mapping has string keys; the port keys ids by integer.
  defp labels_by_id(by_string) do
    Map.new(by_string, fn {id, label} -> {String.to_integer(id), label} end)
  end
end
