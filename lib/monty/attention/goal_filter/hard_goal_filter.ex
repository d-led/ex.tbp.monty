defmodule Monty.Attention.GoalFilter.HardGoalFilter do
  @moduledoc """
  Keep only the goals that land in a place attention wants looked at: Monty's
  `attention/goal_filter.py::HardGoalFilter`.

  The rules, in Monty's order:

    - an empty grid filters nothing — it has no opinion yet;
    - a goal that lands outside the grid is dropped, unless *every* voxel is
      inhibited, in which case the grid means "not here" everywhere and a goal
      elsewhere is as good as any;
    - a goal in an inhibited voxel is dropped;
    - a goal in a positively weighted voxel is kept.

  A goal that carries no location is never filtered: it is not a place, so there
  is nothing to look up, and the filter's job is about places. Such goals come
  back after the ones that were looked up, in Monty's order.
  """

  @behaviour Monty.Attention.GoalFilter

  alias Monty.Attention.VoxelGrid

  @impl Monty.Attention.GoalFilter
  def filter(%VoxelGrid{} = grid, goals) do
    if VoxelGrid.size(grid) == 0 or goals == [] do
      goals
    else
      {located, unlocated} = Enum.split_with(goals, &(&1.location != nil))
      weights = VoxelGrid.weights_at_points(grid, Enum.map(located, & &1.location))
      inhibited? = grid |> VoxelGrid.weights() |> Enum.all?(&(&1 < 0))

      located
      |> Enum.zip(weights)
      |> Enum.filter(fn {_goal, weight} -> keep?(weight, inhibited?) end)
      |> Enum.map(fn {goal, _weight} -> goal end)
      |> Kernel.++(unlocated)
    end
  end

  # A goal outside the grid has no weight at all. Every voxel being inhibited is
  # the grid saying "not here" everywhere, so "elsewhere" is not refused.
  defp keep?(nil, inhibited?), do: inhibited?

  defp keep?(weight, _inhibited?), do: weight > 0
end
