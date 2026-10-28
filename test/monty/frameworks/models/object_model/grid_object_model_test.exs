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

      assert [[x, 0.0, 0.0]] = GridObjectModel.positions(built)
      assert_in_delta x, 0.02, 1.0e-9
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

  defp length_of(vector), do: :math.sqrt(Enum.sum(Enum.map(vector, &(&1 * &1))))
end
