defmodule Monty.Attention.Merge do
  @moduledoc """
  How two grids become one — Monty's `attention/merge.py`.

  Attention can have more than one source of opinion in a step, and the merged
  grid is what the goal filter then reads. Two grids can only be merged if they
  share a scale: a voxel of one size cannot be unioned with a voxel of another,
  because the result would not be a grid.

  Monty names the merge operation `VoxelGridMerge` (a `Protocol`) and ships one
  implementation, `Union`; the size check is a private function of this module.
  """

  alias Monty.Attention.VoxelGrid

  @doc """
  Refuse two grids that cannot be merged: different voxel sizes.

  Different sizes would mean two grids that cannot agree on what a voxel is, so
  the merge is refused by name rather than silently reinterpreted.
  """
  @spec check_can_merge!(VoxelGrid.t(), VoxelGrid.t()) :: :ok
  def check_can_merge!(%VoxelGrid{} = grid_a, %VoxelGrid{} = grid_b) do
    if VoxelGrid.voxel_size(grid_a) != VoxelGrid.voxel_size(grid_b) do
      raise ArgumentError,
            "voxel sizes must match for merging, got #{VoxelGrid.voxel_size(grid_a)} " <>
              "and #{VoxelGrid.voxel_size(grid_b)}"
    end

    :ok
  end
end
