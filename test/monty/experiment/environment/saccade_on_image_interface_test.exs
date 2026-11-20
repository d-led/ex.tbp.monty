defmodule Monty.Experiment.Environment.SaccadeOnImageInterfaceTest do
  # What a config's `scenes` and `versions` mean for an image experiment: one
  # episode per version, in order, wrapping at the end, and the episode's target
  # named from the capture it is on. Monty's class
  # (`experiment/environment.py::SaccadeOnImageInterface`) is the source of both
  # rules; the world it switches is checked, because a cycle that names a capture
  # without loading it would leave every episode on the first one.

  use ExUnit.Case, async: true

  alias ExTbpMonty.Core.Png
  alias Monty.Experiment.Environment.SaccadeOnImageInterface
  alias Monty.Frameworks.Environments.TwoDData.SaccadeOnImageEnvironment

  @patch_size 8
  @image_size 32

  setup do
    scene_path = Path.join(System.tmp_dir!(), "scenes_#{System.unique_integer([:positive])}")
    write_scene(scene_path, "0_numenta_mug", [0, 1])
    write_scene(scene_path, "1_numenta_mug_flipped", [0])
    on_exit(fn -> File.rm_rf(scene_path) end)

    environment = SaccadeOnImageEnvironment.new(data_path: scene_path, patch_size: @patch_size)

    interface =
      SaccadeOnImageInterface.new(
        scenes: [0, 0, 1],
        versions: [0, 1, 0],
        object_names: environment.scenes
      )

    {:ok, interface: interface, environment: environment}
  end

  test "an episode is one version, and the world is on the capture it names",
       %{interface: interface, environment: environment} do
    assert {:ok, first, environment} =
             SaccadeOnImageInterface.change_object_by_idx(interface, 1, environment)

    assert SaccadeOnImageInterface.capture(first) == {0, 1}
    assert %{scene: "0_numenta_mug", version: 1} = environment
    assert first.primary_target["object_name"] == "numenta_mug"
  end

  test "the next episode is the next version, wrapping at the end of the list",
       %{interface: interface, environment: environment} do
    {:ok, last, environment} =
      SaccadeOnImageInterface.change_object_by_idx(interface, 2, environment)

    assert %{scene: "1_numenta_mug_flipped"} = environment

    assert {:ok, wrapped, environment} =
             SaccadeOnImageInterface.post_episode(last, environment)

    assert SaccadeOnImageInterface.capture(wrapped) == {0, 0}
    assert %{scene: "0_numenta_mug", version: 0} = environment
    assert wrapped.episodes == 1
  end

  test "a version the config does not have is refused in Monty's words", %{
    interface: interface,
    environment: environment
  } do
    assert {:error, "idx must satisfy 0 <= idx < 3, got 3"} =
             SaccadeOnImageInterface.change_object_by_idx(interface, 3, environment)
  end

  test "a target's name is its scene directory without the index Monty sorts by" do
    assert SaccadeOnImageInterface.target_object_name("0_numenta_mug") == "numenta_mug"

    assert SaccadeOnImageInterface.target_object_name("12_numenta_mug_flipped") ==
             "numenta_mug_flipped"
  end

  defp write_scene(path, scene, versions) do
    File.mkdir_p!(Path.join(path, scene))

    for version <- versions do
      colour =
        for row <- 0..(@image_size - 1), into: <<>> do
          for column <- 0..(@image_size - 1),
              into: <<>>,
              do: <<rem(row * 8 + version, 256), rem(column * 8, 256), 128>>
        end

      File.write!(
        Path.join([path, scene, "rgb_#{version}.png"]),
        Png.rgb_bytes(colour, @image_size, @image_size)
      )

      File.write!(
        Path.join([path, scene, "depth_#{version}.data"]),
        for(
          row <- 0..(@image_size - 1),
          column <- 0..(@image_size - 1),
          into: <<>>,
          do: <<0.2 + 0.001 * (row + column)::float-little-32>>
        )
      )
    end
  end
end
