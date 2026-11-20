defmodule Monty.Frameworks.Environments.TwoDData.SaccadeOnImageEnvironmentTest do
  # Monty's own integration cases for this world
  # (`tests/integration/frameworks/environments/saccade_on_image_environment_test.py`),
  # one for one plus the capture reading they take for granted: a scene is a
  # colour image with its depth, and an action moves a window over it without
  # moving the camera's own 3-D position except through the surface under it.

  use ExUnit.Case, async: true

  alias ExTbpMonty.Core.Png
  alias Monty.Frameworks.Environments.TwoDData.SaccadeOnImageEnvironment

  @patch_size 8
  @image_size 32

  setup do
    scene = Path.join(System.tmp_dir!(), "scene_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scene, "0_mug"))
    on_exit(fn -> File.rm_rf(scene) end)

    # A depth that changes with both axes, so a window that moves reads a
    # different point: a flat image would make every saccade look like no
    # movement, which is the one thing these cases are about.
    depth =
      for row <- 0..(@image_size - 1) do
        for column <- 0..(@image_size - 1), do: 0.2 + 0.001 * (row + column)
      end

    write_capture(scene, "0_mug", depth)

    environment =
      SaccadeOnImageEnvironment.new(
        data_path: scene,
        patch_size: @patch_size
      )

    {:ok, environment: environment}
  end

  describe "the camera" do
    test "has the iPad's field of view and reach, as Monty's does", %{environment: environment} do
      assert environment.hfov == 54.201
      assert environment.depth_clip_value == 1.1
    end
  end

  describe "an action that is not a saccade" do
    test "does not move the sensor", %{environment: environment} do
      before = position(environment)

      assert moved(environment, %{name: "move_forward", distance: 1}) == {before, 0.0}
      assert moved(environment, %{name: "move_forward", distance: -1}) == {before, 0.0}
    end
  end

  describe "a saccade" do
    test "moves the sensor, whichever of the four it is", %{environment: environment} do
      for action <- ["look_up", "look_down", "turn_left", "turn_right"] do
        {_before, distance} = moved(environment, %{name: action, rotation_degrees: 10})

        assert distance > 0.0001,
               "#{action} left the sensor where it was, and Monty's case says it must not"
      end
    end

    test "keeps the window inside the image", %{environment: environment} do
      # Twelve pixels at a time from the middle of a 32-pixel image: the window
      # reaches the border after one step and stops there, because a patch that
      # ran off the edge would not be a patch.
      %{move_area: [[low_row, high_row], [low_column, high_column]]} = environment

      loc =
        Enum.reduce(1..12, environment, fn _, environment ->
          {_observations, _state, moved} =
            SaccadeOnImageEnvironment.step(environment, [
              %{name: "look_down", rotation_degrees: 12},
              %{name: "turn_right", rotation_degrees: 12}
            ])

          moved
        end).loc

      assert loc == [high_row, high_column]
      assert [low_row, low_column] == [5, 5]
    end
  end

  describe "what the sensors are given" do
    test "is a patch of the patch's size, and the whole capture for the view finder",
         %{environment: environment} do
      {observations, _state, _environment} = SaccadeOnImageEnvironment.step(environment, [])
      %{"patch" => patch, "view_finder" => view_finder} = observations["agent_id_0"]

      assert length(patch["depth"]) == @patch_size
      assert length(hd(patch["depth"])) == @patch_size
      assert length(patch["semantic_3d"]) == @patch_size * @patch_size
      assert length(view_finder["depth"]) == @image_size
      assert length(view_finder["rgba"]) == @image_size
    end
  end

  describe "depth a sensor can use" do
    test "keeps what is near and calls everything else no return" do
      assert [[0.3, 10.0], [0.2, 10.0]] =
               SaccadeOnImageEnvironment.process_depth_data([[0.3, 0.5], [0.2, 10.0]])
    end

    test "reads a word that is not a distance as a missing return" do
      # A capture's depth can say "no return" as a NaN, which the BEAM has no
      # float for: it is recognised in the bytes, not after them.
      file = Path.join(System.tmp_dir!(), "depth_#{System.unique_integer([:positive])}.data")

      File.write!(
        file,
        <<0.25::float-little-32, 0x7FC00000::little-32, 0.5::float-little-32,
          0.125::float-little-32>>
      )

      on_exit(fn -> File.rm(file) end)

      assert [[0.25, 10.0], [0.5, 0.125]] = SaccadeOnImageEnvironment.load_depth_data(file, 2, 2)
    end
  end

  describe "a directory with no scene" do
    test "is refused rather than read as an empty world" do
      empty = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf(empty) end)

      assert_raise ArgumentError, ~r/holds no scene/, fn ->
        SaccadeOnImageEnvironment.new(data_path: empty)
      end
    end
  end

  defp write_capture(scene, name, depth) do
    directory = Path.join(scene, name)

    colour =
      for row <- 0..(@image_size - 1), into: <<>> do
        for column <- 0..(@image_size - 1), into: <<>> do
          <<row * 8, column * 8, 128>>
        end
      end

    File.write!(
      Path.join(directory, "rgb_0.png"),
      Png.rgb_bytes(colour, @image_size, @image_size)
    )

    File.write!(
      Path.join(directory, "depth_0.data"),
      for(row <- depth, value <- row, into: <<>>, do: <<value::float-little-32>>)
    )
  end

  defp position(environment) do
    {_observations, state, _environment} = SaccadeOnImageEnvironment.step(environment, [])
    state["agent_id_0"].sensors["patch"].position
  end

  defp moved(environment, action) do
    before = position(environment)
    after_the_action = position_after(environment, action)

    {before, distance(before, after_the_action)}
  end

  defp position_after(environment, action) do
    {_observations, state, _environment} = SaccadeOnImageEnvironment.step(environment, [action])
    state["agent_id_0"].sensors["patch"].position
  end

  defp distance(from, to) do
    :math.sqrt(Enum.sum(Enum.zip_with(from, to, fn a, b -> (a - b) * (a - b) end)))
  end
end
