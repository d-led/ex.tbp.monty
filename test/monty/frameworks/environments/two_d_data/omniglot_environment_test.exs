defmodule Monty.Frameworks.Environments.TwoDData.OmniglotEnvironmentTest do
  # What this world does with a drawing: walks the pen's path, makes a depth from
  # the ink, and answers the patch and the whole picture to its two sensors.
  #
  # Monty has no unit test for this class — its only coverage is the tutorial,
  # which draws real characters — so these are behaviour tests rather than
  # translations. They run on the small dataset in `OmniglotFixture`, whose stroke
  # is a known diagonal, so the arithmetic is checkable by eye.
  #
  # Monty's own numbers were measured against his class on the first character of
  # his dataset (`docs/monty-differences.md` §2.39): the same 190 pen positions,
  # the same semantic map, and a depth that differs by one unit in the last place
  # because the separable Gaussian is summed in the other order.

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Environments.TwoDData
  alias Monty.Frameworks.Environments.TwoDData.OmniglotEnvironment

  setup do
    path = OmniglotFixture.write(["Alpha", "Beta"])
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, path: path, world: OmniglotEnvironment.new(data_path: path, patch_size: 10)}
  end

  describe "a world over a drawing" do
    test "starts at the first place along the pen's path a patch fits", %{world: world} do
      {observations, state, world} =
        OmniglotEnvironment.step(OmniglotEnvironment.reset(world), [])

      assert location_of(state) == hd(OmniglotFixture.path())
      assert observations["agent_id_0"]["patch"]["depth"] |> length() == 10
      assert world.step_num == 0
    end

    test "walks the path by the amount the action asks for", %{world: world} do
      {_observations, state, world} =
        OmniglotEnvironment.step(world, [%{name: "turn_right", rotation_degrees: 2}])

      assert location_of(state) == Enum.at(OmniglotFixture.path(), 2)
      assert world.step_num == 2
    end

    test "an action that asks for less than a point still moves one", %{world: world} do
      {_observations, state, _world} =
        OmniglotEnvironment.step(world, [%{name: "turn_right", rotation_degrees: 0}])

      assert location_of(state) == Enum.at(OmniglotFixture.path(), 1)
    end

    test "starts the path again when it reaches the end of it", %{world: world} do
      {_observations, state, _world} =
        OmniglotEnvironment.step(%{world | step_num: world.max_steps}, [])

      assert location_of(state) == hd(OmniglotFixture.path())
    end

    test "keeps only the points a whole patch fits at", %{world: world} do
      assert length(world.locations) == 5
      assert world.max_steps == 4

      assert Enum.all?(world.locations, fn [column, row] ->
               column > 10 and row > 10 and column < 20 and row < 20
             end)
    end

    test "makes the depth from the ink: the stroke is nearer than the paper, and the paper is far",
         %{world: world} do
      {observations, _state, _world} = OmniglotEnvironment.step(world, [])
      depth = observations["agent_id_0"]["patch"]["depth"] |> List.flatten()

      # Monty's line is `1.2 - gaussian_filter(~patch, sigma=0.5)`: the paper is
      # the far wall exactly, and the ink comes towards the sensor. A one-pixel
      # stroke is never wholly ink after half a pixel of Gaussian, so the nearest
      # reading is well short of the 20 cm a solid stroke would reach.
      assert Enum.max(depth) == 1.2
      assert Enum.min(depth) < 0.6
    end

    test "tells the sensors where the ink is, and the view finder what the drawing is",
         %{world: world} do
      {observations, _state, _world} = OmniglotEnvironment.step(world, [])
      patch = observations["agent_id_0"]["patch"]
      view_finder = observations["agent_id_0"]["view_finder"]

      assert patch["semantic"] |> List.flatten() |> Enum.sum() > 0
      assert patch["rgba"] |> hd() |> hd() |> length() == 3
      assert view_finder["depth"] == world.image
      assert view_finder["semantic"] == patch["semantic"]
    end

    test "loads the character an episode names", %{world: world} do
      world = OmniglotEnvironment.switch_to_object(world, 1, 1, 1)

      assert world.alphabet == "Beta"
      assert world.character_id == 1
      assert world.character_version == 1
    end

    test "refuses a directory that holds no alphabet" do
      path = Path.join(System.tmp_dir!(), "empty_omniglot_#{System.unique_integer([:positive])}")
      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf(path) end)

      assert_raise ArgumentError, ~r/holds no alphabet/, fn ->
        OmniglotEnvironment.new(data_path: path)
      end
    end
  end

  describe "a pen's path" do
    test "is read as the strokes the file records" do
      path = Path.join(OmniglotFixture.write(), "strokes.txt")
      File.write!(path, "START\n1.0,2.0,0\n3.0,4.0,60\nBREAK\nSTART\n5.0,6.0,120\nBREAK\n")

      assert TwoDData.load_motor(path) == [
               [[1.0, 2.0, 0.0], [3.0, 4.0, 60.0]],
               [[5.0, 6.0, 120.0]]
             ]
    end

    test "in the picture's coordinates has its up-axis flipped" do
      assert TwoDData.space_motor_to_img([[1.0, 2.0, 0.0]]) == [[1.0, -2.0, 0.0]]
    end
  end

  # Monty's position is the path point as the picture counts it: its first
  # coordinate the column, its second the row.
  defp location_of(state) do
    sensor = state["agent_id_0"].sensors["patch"]
    [Enum.at(sensor.position, 0), Enum.at(sensor.position, 1)]
  end
end
