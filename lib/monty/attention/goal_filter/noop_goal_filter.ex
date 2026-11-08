defmodule Monty.Attention.GoalFilter.NoopGoalFilter do
  @moduledoc """
  Pass every goal through unchanged: Monty's
  `attention/goal_filter.py::NoopGoalFilter`.

  The default, because a filter that drops a goal changes what the agent does and
  that should be asked for rather than assumed.
  """

  @behaviour Monty.Attention.GoalFilter

  @impl Monty.Attention.GoalFilter
  def filter(_voxel_grid, goals), do: goals
end
