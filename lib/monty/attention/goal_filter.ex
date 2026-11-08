defmodule Monty.Attention.GoalFilter do
  @moduledoc """
  Which goals attention leaves alone — Monty's `attention/goal_filter.py`.

  Attention can *propose* to look somewhere and a goal filter can refuse it: a
  goal that lands in a place the attention system has learned to avoid is not
  worth pursuing this step, however well-specified it is.

  Monty declares the filter as a `Protocol` over `__call__(voxel_grid, goals)`.
  Here it is a behaviour whose `filter/2` is the same call, and the goal it
  filters is this port's `Monty.Cmp.Goal`, whose `location` is `nil` when the goal
  does not say where.
  """

  alias Monty.Attention.VoxelGrid
  alias Monty.Cmp.Goal

  @doc "The goals to pursue, given what attention knows."
  @callback filter(VoxelGrid.t(), [Goal.t()]) :: [Goal.t()]
end
