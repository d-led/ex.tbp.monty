defmodule Monty.Frameworks.Models.ObjectModel.GridObjectModelTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.ObjectModel.{GridObjectModel, GridTooSmallError}
  alias Monty.Geometry.Rotation

  # A grid one metre across, ten voxels per side: a voxel is ten centimetres,
  # and the first observation lands in the middle one.
  defp model(options \\ []) do
    GridObjectModel.new(
      "mug",
      Keyword.merge([max_nodes: 100, max_size: 1.0, num_voxels_per_dim: 10], options)
    )
  end

  defp pose do
    [0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
  end

  # The features a buffer gathers, one row per observation.
  defp features(values) do
    %{
      "value" => Enum.map(values, &[&1]),
      "pose_vectors" => List.duplicate(pose(), length(values)),
      "pose_fully_defined" => List.duplicate([1.0], length(values))
    }
  end

  defp locations(xs), do: Enum.map(xs, &[&1, 0.0, 0.0])

  describe "what the grid keeps" do
    test "the first observation becomes a node where it was seen" do
      {:ok, built} = GridObjectModel.build_model(model(), locations([0.0]), features([0.0]))

      assert GridObjectModel.num_nodes(built) == 1
      assert GridObjectModel.positions(built) == [[0.0, 0.0, 0.0]]
    end

    test "observations that share a voxel become one node" do
      {:ok, built} =
        GridObjectModel.build_model(model(), locations([0.0, 0.04]), features([0.0, 0.1]))

      assert GridObjectModel.num_nodes(built) == 1
    end

    test "observations in different voxels become different nodes" do
      {:ok, built} =
        GridObjectModel.build_model(model(), locations([0.0, 0.2]), features([0.0, 0.2]))

      assert GridObjectModel.num_nodes(built) == 2
    end

    test "a voxel's location is the average of what was seen inside it" do
      {:ok, built} =
        GridObjectModel.build_model(model(), locations([0.0, 0.04]), features([0.0, 0.1]))

      assert [[x, y, z]] = GridObjectModel.positions(built)
      assert_in_delta x, 0.02, 1.0e-9
      # Both observations were on the x axis the fixture walks.
      assert y == 0.0
      assert z == 0.0
    end

    test "only the busiest voxels are kept, and a tie goes to the lower voxel" do
      observations = [0.0, 0.0, 0.2, 0.4]

      {:ok, built} =
        GridObjectModel.build_model(
          model(max_nodes: 2),
          locations(observations),
          features([0.0, 0.0, 0.2, 0.4])
        )

      assert GridObjectModel.num_nodes(built) == 2

      # The voxel seen twice, and the lower of the two seen once.
      assert Enum.map(GridObjectModel.positions(built), fn [x, _, _] -> x end) == [0.0, 0.2]
    end
  end

  # A caller asks whether the model holds a feature before working on it. A grid
  # keeps no column index of its own, and answering `false` for every name told
  # such a caller the model had no features at all, so it dropped every one.
  describe "the features a grid holds" do
    test "a feature the grid was filled with is one it holds" do
      {:ok, built} =
        GridObjectModel.build_model(model(), locations([0.0]), features([0.2]))

      assert GridObjectModel.has_feature?(built, "value")
      refute GridObjectModel.has_feature?(built, "curvature")
    end
  end

  describe "what a voxel averages" do
    test "a feature is the mean of the values seen in that voxel" do
      {:ok, built} =
        GridObjectModel.build_model(model(), locations([0.0, 0.04]), features([0.2, 0.4]))

      assert [[value]] = GridObjectModel.get_values_for_feature(built, "value")
      assert_in_delta value, 0.3, 1.0e-9
    end

    test "a hue is averaged as an angle, not as a number" do
      hues = %{
        "hsv" => [[0.01, 0.5, 0.5], [0.99, 0.5, 0.5]],
        "pose_vectors" => List.duplicate(pose(), 2),
        "pose_fully_defined" => List.duplicate([1.0], 2)
      }

      {:ok, built} =
        GridObjectModel.build_model(
          model(),
          locations([0.0, 0.04]),
          hues
        )

      assert [[hue, _saturation, _value]] = GridObjectModel.get_values_for_feature(built, "hsv")

      # 0.01 and 0.99 are either side of red; their mean is red, not cyan.
      assert hue < 0.01 or hue > 0.99
    end

    test "a flag is the majority of the observations, not their mean" do
      flags = %{
        "on_object" => [[1.0], [1.0], [0.0]],
        "pose_vectors" => List.duplicate(pose(), 3),
        "pose_fully_defined" => List.duplicate([1.0], 3)
      }

      {:ok, built} =
        GridObjectModel.build_model(model(), locations([0.0, 0.02, 0.04]), flags)

      assert [[1.0]] = GridObjectModel.get_values_for_feature(built, "on_object")
    end

    test "a pose is averaged as a rotation, so the node still holds a rotation" do
      turned =
        Rotation.to_matrix(Rotation.from_axis_angle([0.0, 0.0, 1.0], :math.pi() / 2) |> elem(1))

      other = List.flatten(turned)

      poses = %{
        "pose_vectors" => [pose(), other],
        "pose_fully_defined" => [[1.0], [1.0]]
      }

      {:ok, built} = GridObjectModel.build_model(model(), locations([0.0, 0.02]), poses)

      assert [flat] = GridObjectModel.get_values_for_feature(built, "pose_vectors")
      assert [normal, curvature_1, curvature_2] = Enum.chunk_every(flat, 3)

      # A rotation's rows are unit vectors; an average of the numbers would not be.
      assert_in_delta length_of(normal), 1.0, 1.0e-6
      assert_in_delta length_of(curvature_1), 1.0, 1.0e-6
      assert_in_delta length_of(curvature_2), 1.0, 1.0e-6
    end
  end

  describe "an observation that does not fit" do
    test "is refused when too much of the object falls outside the grid" do
      # Half a metre of grid either way; only the observation at the start fits.
      assert {:error, %GridTooSmallError{fraction_in_bounds: fraction}} =
               GridObjectModel.build_model(
                 model(),
                 locations([0.0, 0.6, 1.2]),
                 features([0.0, 0.6, 1.2])
               )

      assert_in_delta fraction, 1 / 3, 1.0e-9
    end

    test "says how much of the object did fit" do
      {:error, error} =
        GridObjectModel.build_model(model(), locations([0.0, 1.2]), features([0.0, 1.2]))

      assert Exception.message(error) =~ "50.0%"
    end
  end

  describe "adding a second look at the same voxel" do
    test "averages the two averages rather than weighting by observations" do
      {:ok, built} =
        GridObjectModel.build_model(model(), locations([0.0, 0.0]), features([0.0, 1.0]))

      {:ok, updated} =
        GridObjectModel.update_model(
          built,
          locations([0.0, 0.0, 0.0, 0.0]),
          features([1.0, 1.0, 1.0, 1.0]),
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 0.0],
          Rotation.identity()
        )

      assert [[value]] = GridObjectModel.get_values_for_feature(updated, "value")

      # The stored 0.5 and the new 1.0 average to 0.75. A mean weighted by the
      # six observations would be 0.833 — Monty averages the averages.
      assert_in_delta value, 0.75, 1.0e-9
    end
  end

  describe "a graph learned elsewhere" do
    test "is adopted as it stands when the model asks for that" do
      graph = %{
        x: [[1.0]],
        pos: [[0.5, 0.5, 0.5]],
        feature_mapping: %{"value" => {0, 1}}
      }

      {:ok, model} = GridObjectModel.set_graph(model(use_original_graph: true), graph)

      assert GridObjectModel.positions(model) == [[0.5, 0.5, 0.5]]
      assert GridObjectModel.get_values_for_feature(model, "value") == [[1.0]]
    end

    test "is re-thinned to this model's grid when it is not" do
      graph = %{
        x: [[1.0], [2.0]],
        pos: [[0.0, 0.0, 0.0], [0.02, 0.0, 0.0]],
        feature_mapping: %{"value" => {0, 1}}
      }

      {:ok, model} = GridObjectModel.set_graph(model(), graph)

      # The two nodes share a voxel, so the grid holds one node with their mean.
      assert GridObjectModel.num_nodes(model) == 1
      assert [[value]] = GridObjectModel.get_values_for_feature(model, "value")
      assert_in_delta value, 1.5, 1.0e-9
    end
  end

  # -- Monty's own cases ---------------------------------------------------

  # Monty's `ObjectModelTest` cases that are about a grid model, over its
  # `dummy_locs` and `dummy_features`. Monty's numbers are centimetres and this
  # port's are metres, so every length below is Monty's over a hundred: a grid
  # ten centimetres across with ten voxels a side is `max_size: 0.10,
  # num_voxels_per_dim: 10`.
  describe "Monty's own cases" do
    # test_create_grid_object_model
    test "a model is a model before anything is built into it" do
      model =
        GridObjectModel.new("test_model", max_nodes: 10, max_size: 0.10, num_voxels_per_dim: 10)

      assert model.object_id == "test_model"
      assert GridObjectModel.graph(model) == nil
      assert is_binary(inspect(model))
    end

    # test_can_build_grid_object_model
    test "a centimetre's voxels keep the four observations apart" do
      {:ok, built} =
        GridObjectModel.build_model(centimetre_grid(), dummy_locations(), dummy_features())

      assert GridObjectModel.num_nodes(built) == 4

      for feature <- Map.keys(dummy_features()) do
        assert GridObjectModel.has_feature?(built, feature), "#{feature} is not stored"
      end
    end

    # test_grid_locations_binned_correctly
    test "two-centimetre voxels bin them together, and average where they were" do
      {:ok, built} =
        GridObjectModel.build_model(two_centimetre_grid(), dummy_locations(), dummy_features())

      # The observation a centimetre out sits exactly on this grid's boundary,
      # and numpy's rounding — a half to its even neighbour — keeps it in the
      # first observation's voxel.
      assert GridObjectModel.num_nodes(built) == 1
      assert [[x, y, z]] = GridObjectModel.positions(built)
      # The average of [0, 0], [0, 1], [1, 0] and [1, 1] centimetres.
      assert_in_delta x, 0.005, 1.0e-9
      assert_in_delta y, 0.005, 1.0e-9
      assert z == 0.0
    end

    # test_grid_features_are_averaged_correctly
    test "a voxel's features are the average of what was seen inside it" do
      {:ok, built} =
        GridObjectModel.build_model(two_centimetre_grid(), dummy_locations(), dummy_features())

      [pose] = GridObjectModel.get_values_for_feature(built, "pose_vectors")
      # Every observation's pose is the identity, so the average is too.
      assert_close(pose, identity_pose())

      assert GridObjectModel.get_values_for_feature(built, "pose_fully_defined") == [[1.0]]

      [hsv] = GridObjectModel.get_values_for_feature(built, "hsv")
      # A circular average, where 0 and 1 are one hue.
      assert_close(hsv, [0.95, 1.0, 1.0])

      assert [[curvature]] = GridObjectModel.get_values_for_feature(built, "curvature")
      assert_in_delta curvature, 1.0, 1.0e-9

      # A majority vote decides the pose's own flag: one of four is not enough…
      features =
        Map.put(dummy_features(), "pose_fully_defined", [[0.0], [0.0], [0.0], [1.0]])

      {:ok, majority_no} =
        GridObjectModel.build_model(two_centimetre_grid(), dummy_locations(), features)

      assert GridObjectModel.get_values_for_feature(majority_no, "pose_fully_defined") == [[0.0]]

      # …and a tie is a yes.
      features = Map.put(dummy_features(), "pose_fully_defined", [[1.0], [0.0], [0.0], [1.0]])

      {:ok, tied} =
        GridObjectModel.build_model(two_centimetre_grid(), dummy_locations(), features)

      assert GridObjectModel.get_values_for_feature(tied, "pose_fully_defined") == [[1.0]]

      # A pose turned to the other side of the surface is left out of the
      # average while it is the odd one out…
      opposite = opposite_pose()

      one_away =
        Map.put(
          dummy_features(),
          "pose_vectors",
          List.replace_at(dummy_pose_vectors(), 0, opposite)
        )

      {:ok, odd_one} =
        GridObjectModel.build_model(two_centimetre_grid(), dummy_locations(), one_away)

      [averaged] = GridObjectModel.get_values_for_feature(odd_one, "pose_vectors")
      assert_close(averaged, identity_pose())

      # …and becomes the average once most of them are on that side.
      three_away =
        Map.put(
          dummy_features(),
          "pose_vectors",
          dummy_pose_vectors()
          |> List.replace_at(0, opposite)
          |> List.replace_at(1, opposite)
          |> List.replace_at(2, opposite)
        )

      {:ok, majority_away} =
        GridObjectModel.build_model(two_centimetre_grid(), dummy_locations(), three_away)

      [turned] = GridObjectModel.get_values_for_feature(majority_away, "pose_vectors")
      assert_close(turned, opposite)

      # An average of poses is still a rotation: unit rows, at right angles.
      rotated =
        Map.put(
          dummy_features(),
          "pose_vectors",
          List.replace_at(dummy_pose_vectors(), 0, rotated_pose(20.0))
        )

      {:ok, skewed} =
        GridObjectModel.build_model(two_centimetre_grid(), dummy_locations(), rotated)

      [average_of_rotated] = GridObjectModel.get_values_for_feature(skewed, "pose_vectors")

      assert_orthonormal(average_of_rotated)
    end

    # test_update_model_keeps_pose_vectors_as_rotation_matrix
    test "pose vectors averaged into the model stay a rotation" do
      for defined <- [1.0, 0.0] do
        {:ok, built} =
          GridObjectModel.build_model(two_centimetre_grid(), dummy_locations(), dummy_features())

        features =
          dummy_features()
          |> Map.put("pose_vectors", List.duplicate(opposite_pose(), 4))
          |> Map.put("pose_fully_defined", List.duplicate([defined], 4))

        {:ok, updated} =
          Enum.reduce(1..3, {:ok, built}, fn _step, {:ok, model} ->
            GridObjectModel.update_model(
              model,
              dummy_locations(),
              features,
              [0.0, 0.0, 0.0],
              [0.0, 0.0, 0.0],
              Rotation.identity()
            )
          end)

        for pose <- GridObjectModel.get_values_for_feature(updated, "pose_vectors") do
          assert_orthonormal(pose)
          assert_in_delta determinant(pose), 1.0, 1.0e-3
        end
      end
    end

    # test_max_nodes_applied_correctly
    test "a grid keeps no more nodes than it is allowed" do
      model =
        GridObjectModel.new("test_model", max_nodes: 3, max_size: 0.10, num_voxels_per_dim: 10)

      {:ok, built} = GridObjectModel.build_model(model, dummy_locations(), dummy_features())

      assert GridObjectModel.num_nodes(built) == 3
    end

    # test_max_size_applied_correctly
    test "and refuses observations it cannot hold" do
      model =
        GridObjectModel.new("test_model", max_nodes: 10, max_size: 0.01, num_voxels_per_dim: 10)

      assert {:error, %GridTooSmallError{}} =
               GridObjectModel.build_model(model, dummy_locations(), dummy_features())
    end
  end

  # Monty's `dummy_locs`, in metres.
  defp dummy_locations do
    [[0.0, 0.0, 0.0], [0.0, 0.01, 0.0], [0.01, 0.0, 0.0], [0.01, 0.01, 0.0]]
  end

  # A grid ten centimetres across with a voxel every centimetre…
  defp centimetre_grid do
    GridObjectModel.new("test_model", max_nodes: 10, max_size: 0.10, num_voxels_per_dim: 10)
  end

  # …and the same grid with a voxel every two.
  defp two_centimetre_grid do
    GridObjectModel.new("test_model", max_nodes: 10, max_size: 0.10, num_voxels_per_dim: 5)
  end

  defp identity_pose, do: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]

  defp dummy_pose_vectors, do: List.duplicate(identity_pose(), 4)

  # Monty's `dummy_features`: one row per observation, as a buffer gathers them.
  defp dummy_features do
    %{
      "pose_vectors" => dummy_pose_vectors(),
      "pose_fully_defined" => List.duplicate([1.0], 4),
      "hsv" => [[0.1, 1.0, 1.0], [0.0, 1.0, 1.0], [0.9, 1.0, 1.0], [0.8, 1.0, 1.0]],
      "curvature" => [[0.0], [1.0], [2.0], [1.0]]
    }
  end

  # The identity turned half way round the vertical: the same surface normal,
  # the other two directions negated.
  defp opposite_pose, do: [-1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 1.0]

  # The identity turned by `degrees` about the vertical, flattened.
  defp rotated_pose(degrees) do
    {:ok, rotation} = Rotation.from_euler_degrees([0.0, 0.0, degrees])

    [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
    |> Enum.map(&Rotation.apply(rotation, &1))
    |> List.flatten()
  end

  defp assert_close(actual, expected) do
    for {mine, theirs} <- Enum.zip(actual, expected) do
      assert_in_delta mine,
                      theirs,
                      1.0e-9,
                      "expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end

  # Monty's `check_orthonormal`: three unit rows at right angles.
  defp assert_orthonormal(pose) do
    [first, second, third] = Enum.chunk_every(pose, 3)

    for vector <- [first, second, third] do
      assert_in_delta length_of(vector), 1.0, 1.0e-6
    end

    assert_in_delta dot(first, second), 0.0, 1.0e-6
    assert_in_delta dot(first, third), 0.0, 1.0e-6
    assert_in_delta dot(second, third), 0.0, 1.0e-6
  end

  defp determinant(pose) do
    [first, second, third] = Enum.chunk_every(pose, 3)

    dot(first, cross(second, third))
  end

  defp dot(left, right), do: Enum.zip_with(left, right, &(&1 * &2)) |> Enum.sum()

  defp cross([a1, a2, a3], [b1, b2, b3]),
    do: [a2 * b3 - a3 * b2, a3 * b1 - a1 * b3, a1 * b2 - a2 * b1]

  defp length_of(vector), do: :math.sqrt(Enum.sum(Enum.map(vector, &(&1 * &1))))
end
