defmodule Monty.Attention.GoalFilterTest do
  @moduledoc """
  Translations of `tests/unit/attention/goal_filter_test.py` (six cases: one for
  `NoopGoalFilter`, five for `HardGoalFilter`).

  Monty's fixture `voxel_grid_and_goals` builds a grid and three sets of goals —
  inside positively weighted voxels, inside negatively weighted voxels, and
  outside the grid — and each case hands one set to the filter. `grid_and_goals/1`
  below is that fixture, with the weight mix the case needs drawn explicitly
  because Monty's three weight strategies (`all_negative`, `with_positive`,
  `with_negative`) are what select the rule under test.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Attention.GoalFilter.{HardGoalFilter, NoopGoalFilter}
  alias Monty.Attention.VoxelGrid
  alias Monty.Cmp.Goal

  defp voxel do
    tuple({integer(-100..100), integer(-100..100), integer(-100..100)})
  end

  defp centre({x, y, z}, voxel_size) do
    [(x + 0.5) * voxel_size, (y + 0.5) * voxel_size, (z + 0.5) * voxel_size]
  end

  defp goal_at(location) do
    {:ok, goal} = Goal.new(%{sender_id: "attention-test", sender_type: :gsg, location: location})
    goal
  end

  defp goal_anywhere do
    {:ok, goal} = Goal.new(%{sender_id: "attention-test", sender_type: :gsg})
    goal
  end

  # Monty's `voxel_grid_and_goals`, with the weight mix the case needs: `:any`,
  # `:all_negative` (no voxel says "look here") or `:with_positive` (at least one
  # voxel does).
  defp grid_and_goals(mix) do
    gen all(
          voxel_size <- float(min: 0.001, max: 1.0),
          candidates <- uniq_list_of(voxel(), min_length: 2, max_length: 6),
          occupied_count <- integer(1..(length(candidates) - 1)),
          drawn <- list_of(float(min: -1.0, max: 1.0), length: occupied_count)
        ) do
      {occupied, outside} = Enum.split(candidates, occupied_count)
      weighted = weights(drawn, mix)

      {positive, negative} =
        occupied |> Enum.zip(weighted) |> Enum.split_with(fn {_, w} -> w > 0 end)

      %{
        grid: VoxelGrid.new(voxel_size, occupied, weighted),
        voxel_size: voxel_size,
        in_positive: Enum.map(positive, fn {v, _} -> goal_at(centre(v, voxel_size)) end),
        in_negative: Enum.map(negative, fn {v, _} -> goal_at(centre(v, voxel_size)) end),
        out_of_grid: Enum.map(outside, &goal_at(centre(&1, voxel_size)))
      }
    end
  end

  defp weights(drawn, :any), do: drawn
  defp weights(drawn, :all_negative), do: Enum.map(drawn, &(-abs(&1) - 0.5))
  defp weights([first | rest], :with_positive), do: [abs(first) + 0.5 | rest]
  defp weights([], :with_positive), do: []

  describe "NoopGoalFilter.filter/2 (NoopGoalFilterTest)" do
    # test_noop_goal_filter_returns_all_goals
    property "returns every goal" do
      check all(
              goals <-
                list_of(member_of([goal_anywhere(), goal_at([0.0, 0.0, 0.0])]), max_length: 5)
            ) do
        assert NoopGoalFilter.filter(VoxelGrid.empty(1.0), goals) == goals
      end
    end
  end

  describe "HardGoalFilter.filter/2 (HardGoalFilterTest)" do
    # test_out_of_grid_goals_pass_when_grid_is_empty
    test "an empty grid has no opinion, so every goal passes" do
      goals = [goal_anywhere(), goal_at([1000.0, 1000.0, 1000.0])]

      assert HardGoalFilter.filter(VoxelGrid.empty(1.0), goals) == goals
    end

    # test_out_of_grid_goals_pass_when_all_voxel_weights_are_negative
    property "goals outside the grid pass when every voxel is inhibited" do
      check all(%{grid: grid, out_of_grid: goals} <- grid_and_goals(:all_negative)) do
        assert HardGoalFilter.filter(grid, goals) == goals
      end
    end

    # test_out_of_grid_goals_filtered_out_when_there_are_voxels_with_positive_weights
    property "goals outside the grid are dropped when some voxel says look here" do
      check all(%{grid: grid, out_of_grid: goals} <- grid_and_goals(:with_positive)) do
        assert HardGoalFilter.filter(grid, goals) == []
      end
    end

    # test_goals_in_voxels_with_negative_weights_filtered
    property "goals in inhibited voxels are dropped" do
      check all(%{grid: grid, in_negative: goals} <- grid_and_goals(:any)) do
        assert HardGoalFilter.filter(grid, goals) == []
      end
    end

    # test_goals_in_voxels_with_positive_weights_pass
    property "goals in positively weighted voxels pass" do
      check all(%{grid: grid, in_positive: goals} <- grid_and_goals(:with_positive)) do
        assert HardGoalFilter.filter(grid, goals) == goals
      end
    end
  end

  describe "HardGoalFilter.filter/2 (the rules stated in Monty's docstring)" do
    test "a goal that carries no location is never filtered, and comes back last" do
      grid = VoxelGrid.new(1.0, [{0, 0, 0}, {1, 0, 0}], [0.5, -0.5])
      located = goal_at([0.5, 0.5, 0.5])
      unlocated = goal_anywhere()

      assert HardGoalFilter.filter(grid, [located, unlocated]) == [located, unlocated]
      assert HardGoalFilter.filter(grid, [unlocated]) == [unlocated]
    end
  end
end
