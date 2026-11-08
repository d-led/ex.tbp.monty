defmodule Monty.Attention.Merge.VoxelGridMerge do
  @moduledoc """
  The contract a merge satisfies — Monty's `attention/merge.py::VoxelGridMerge`.

  Two grids in, one grid out. Monty declares it as a `Protocol` over
  `__call__(grid_a, grid_b)`; here it is the `merge/2` behaviour.
  """

  alias Monty.Attention.VoxelGrid

  @doc "Merge the second grid into the first."
  @callback merge(VoxelGrid.t(), VoxelGrid.t()) :: VoxelGrid.t()
end
