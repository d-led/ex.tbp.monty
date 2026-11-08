defmodule Monty.Attention.VoxelGridTest do
  @moduledoc """
  Translations of `tests/unit/attention/voxel_grid_test.py`.

  Cases that cannot be translated: `VoxelGridTest.test_from_pandas_validates_input_using_validate_dataframe`
  and the four `ValidateDataFrameTest` cases, because they build a malformed
  pandas `DataFrame` and check `validate_dataframe` refuses it. A map cannot
  hold the shapes they refuse; what survives of that rule is
  "a grid holds one weight per voxel", which `new/3` enforces.
  `test_init_validates_input_using_validate_dataframe` (a mock-counting case) has
  no counterpart either.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Attention.VoxelGrid

  # Monty's fixtures keep generated points this far, as a fraction of a voxel,
  # from the faces, so that float error cannot move a point into its neighbour.
  @edge_tolerance 1.0e-6

  defp voxel do
    tuple({integer(-100..100), integer(-100..100), integer(-100..100)})
  end

  defp offset_in_voxel, do: member_of([@edge_tolerance, 0.25, 0.5, 0.75, 1 - @edge_tolerance])

  defp point_in({x, y, z}, {dx, dy, dz}, voxel_size) do
    [
      (x + dx) * voxel_size,
      (y + dy) * voxel_size,
      (z + dz) * voxel_size
    ]
  end

  # Monty's `voxelized_and_binned_points`: voxels known to be occupied, points
  # known to fall inside them, and one weight per point.
  defp voxels_and_contained_points do
    gen all(
          voxel_size <- float(min: 0.001, max: 1.0),
          voxels <- uniq_list_of(voxel(), min_length: 1, max_length: 6),
          offsets <-
            list_of(
              tuple({offset_in_voxel(), offset_in_voxel(), offset_in_voxel()}),
              length: length(voxels)
            ),
          weights <- list_of(float(min: -1.0, max: 1.0), length: length(voxels))
        ) do
      voxels = Enum.sort(voxels)

      points =
        [voxels, offsets] |> Enum.zip() |> Enum.map(fn {v, o} -> point_in(v, o, voxel_size) end)

      %{voxel_size: voxel_size, voxels: voxels, points: points, weights: weights}
    end
  end

  describe "voxelize_points/2 (VoxelizePointsTest)" do
    # test_points_not_n_by_3_raises_value_error
    test "refuses points that are not [x, y, z] triples" do
      assert_raise ArgumentError, fn ->
        VoxelGrid.voxelize_points(1.0, [[0.0, 0.0], [1.0, 1.0, 1.0]])
      end
    end

    # test_returned_tuple_list_contains_each_points_voxel
    property "returns the voxel each point is in, in point order" do
      check all(
              %{voxel_size: voxel_size, voxels: voxels, points: points} <-
                voxels_and_contained_points()
            ) do
        assert VoxelGrid.voxelize_points(voxel_size, points) == voxels
      end
    end

    # Monty's docstring: "Voxels are half-open: a point on the face shared by two
    # voxels belongs to the one with the larger coordinate". The negative case is
    # the one `trunc` would get wrong; `floor` is what makes it hold.
    test "puts a point on a shared face in the voxel with the larger coordinate" do
      assert VoxelGrid.voxelize_points(1.0, [
               [0.0, 0.0, 0.0],
               [1.0, 0.0, 0.0],
               [-0.0001, 0.0, 0.0]
             ]) ==
               [{0, 0, 0}, {1, 0, 0}, {-1, 0, 0}]
    end
  end

  describe "voxelize_and_bin_points/3 (VoxelizeAndBinPointsTest)" do
    # test_weights_not_1d_raises_value_error
    test "refuses weights that are not one per point" do
      assert_raise ArgumentError, fn ->
        VoxelGrid.voxelize_and_bin_points(1.0, [[0.5, 0.5, 0.5], [1.5, 1.5, 1.5]], [0.25])
      end
    end

    # test_returned_dataframe_rows_contain_each_points_voxel_from_voxelize_points_and_weight
    # (Monty patches `voxelize_points` to prove the rows descend from it; here the
    # pair is direct, so the case asserts the rows themselves.)
    property "carries each point's voxel alongside its weight, in point order" do
      check all(
              %{voxel_size: voxel_size, voxels: voxels, points: points, weights: weights} <-
                voxels_and_contained_points()
            ) do
        assert VoxelGrid.voxelize_and_bin_points(voxel_size, points, weights) ==
                 Enum.zip(voxels, weights)
      end
    end
  end

  describe "new/3 (ValidateDataFrameTest, the one rule a map can break)" do
    # test_raises_value_error_if_dataframe_index_is_not_unique
    test "holds one weight per voxel, refusing a voxel given twice" do
      assert_raise ArgumentError, fn ->
        VoxelGrid.new(1.0, [{0, 0, 0}, {0, 0, 0}], [0.5, 0.25])
      end
    end

    test "holds one weight per voxel, refusing a count that does not match" do
      assert_raise ArgumentError, fn -> VoxelGrid.new(1.0, [{0, 0, 0}, {1, 0, 0}], [0.5]) end
    end
  end

  describe "weights_at_points/3 (VoxelGridTest)" do
    # test_weights_at_points_returns_weights_for_occupied_voxels_and_fill_value_for_unoccupied_voxels
    property "answers an occupied voxel's weight, and the fill value elsewhere" do
      check all(
              voxel_size <- float(min: 0.001, max: 1.0),
              candidates <- uniq_list_of(voxel(), min_length: 2, max_length: 6),
              occupied_count <- integer(1..(length(candidates) - 1)),
              weights <- list_of(float(min: -1.0, max: 1.0), length: occupied_count)
            ) do
        {occupied, unoccupied} = Enum.split(candidates, occupied_count)
        grid = VoxelGrid.new(voxel_size, occupied, weights)

        points = Enum.map(candidates, &point_in(&1, {0.5, 0.5, 0.5}, voxel_size))
        expected = weights ++ List.duplicate(nil, length(unoccupied))

        assert VoxelGrid.weights_at_points(grid, points) == expected
      end
    end
  end

  describe "encode/1 (EncodeVoxelGridTest)" do
    # test_buffer_encoder_encodes_voxel_grid
    property "writes the voxel size, the voxels and their weights in parallel" do
      check all(
              %{voxel_size: voxel_size, voxels: voxels, weights: weights} <-
                voxels_and_contained_points()
            ) do
        encoded =
          voxel_size
          |> VoxelGrid.new(voxels, weights)
          |> VoxelGrid.encode()

        assert encoded["voxel_size"] == voxel_size
        assert encoded["voxels"] == Enum.map(voxels, &Tuple.to_list/1)
        assert encoded["weight"] == weights
      end
    end

    test "is JSON-encodable, because Monty writes grids into run recordings" do
      grid = VoxelGrid.new(0.5, [{0, 0, 0}, {1, 0, 0}], [0.25, -1.0])

      assert grid |> VoxelGrid.encode() |> Jason.encode!() |> Jason.decode!() == %{
               "voxel_size" => 0.5,
               "voxels" => [[0, 0, 0], [1, 0, 0]],
               "weight" => [0.25, -1.0]
             }
    end
  end
end
