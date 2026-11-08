defmodule Monty.Attention.MergeTest do
  @moduledoc """
  Translations of `tests/unit/attention/merge_test.py` (two cases, both for
  `Union`).

  Monty's second case patches `pandas.DataFrame.combine_first` and checks that
  `Union` calls it with `(grid_b, grid_a)` — a case about which pandas method is
  used, not about what a merge means. It translates as the behaviour
  `combine_first(grid_b, grid_a)` stands for: where the grids overlap, grid_b's
  weight is the one that survives. `VoxelGridMerge` (the `Protocol`) has no case of
  its own; here it is the `merge/2` behaviour.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Attention.Merge.Union
  alias Monty.Attention.VoxelGrid

  defp voxel do
    tuple({integer(-100..100), integer(-100..100), integer(-100..100)})
  end

  describe "Union.merge/2 (UnionTest)" do
    # test_raises_value_error_if_voxel_sizes_do_not_match
    property "refuses grids whose voxel sizes differ" do
      check all(
              voxel_size <- float(min: 0.001, max: 1.0),
              voxels <- uniq_list_of(voxel(), min_length: 1, max_length: 4),
              other_size <- float(min: 0.001, max: 1.0),
              other_size != voxel_size
            ) do
        grid_a = VoxelGrid.new(voxel_size, voxels, List.duplicate(0.5, length(voxels)))
        grid_b = VoxelGrid.new(other_size, voxels, List.duplicate(0.25, length(voxels)))

        assert_raise ArgumentError, fn -> Union.merge(grid_a, grid_b) end
      end
    end

    # test_returns_voxel_grid_from_grid_b_combine_first_grid_a
    property "occupies every voxel of either grid, with grid_b's weight where they overlap" do
      check all(
              voxels_a <- uniq_list_of(voxel(), min_length: 1, max_length: 4),
              voxels_b <- uniq_list_of(voxel(), min_length: 1, max_length: 4),
              weights_a <- list_of(float(), length: length(voxels_a)),
              weights_b <- list_of(float(), length: length(voxels_b))
            ) do
        grid_a = VoxelGrid.new(1.0, voxels_a, weights_a)
        grid_b = VoxelGrid.new(1.0, voxels_b, weights_b)

        merged = Union.merge(grid_a, grid_b)

        assert VoxelGrid.voxel_size(merged) == 1.0
        assert VoxelGrid.voxels(merged) == Enum.sort(Enum.uniq(voxels_a ++ voxels_b))

        weights_of_b = Map.new(Enum.zip(voxels_b, weights_b))
        weights_of_a = Map.new(Enum.zip(voxels_a, weights_a))

        for {voxel, weight} <-
              Map.new(Enum.zip(VoxelGrid.voxels(merged), VoxelGrid.weights(merged))) do
          if Map.has_key?(weights_of_b, voxel) do
            assert weight == Map.fetch!(weights_of_b, voxel),
                   "where both grids have the voxel, grid_b's weight wins"
          else
            assert weight == Map.fetch!(weights_of_a, voxel)
          end
        end
      end
    end
  end
end
