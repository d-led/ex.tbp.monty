defmodule Monty.Attention.Merge.Union do
  @moduledoc """
  Merge by union, the second grid winning where they overlap: Monty's
  `attention/merge.py::Union`.

  A voxel occupied in either grid is occupied in the result. Where both grids
  have an opinion about the same voxel, the second one's weight is kept — the
  newer opinion, since a caller merges what it just learned into what it already
  knew.
  """

  @behaviour Monty.Attention.Merge.VoxelGridMerge

  alias Monty.Attention.{Merge, VoxelGrid}

  @impl Monty.Attention.Merge.VoxelGridMerge
  def merge(%VoxelGrid{} = grid_a, %VoxelGrid{} = grid_b) do
    :ok = Merge.check_can_merge!(grid_a, grid_b)

    %{grid_a | weights: Map.merge(grid_a.weights, grid_b.weights)}
  end
end
