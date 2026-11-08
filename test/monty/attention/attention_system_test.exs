defmodule Monty.Attention.AttentionSystemTest do
  @moduledoc """
  Translations of `tests/unit/attention/attention_system_test.py` (three cases for
  `NoopAttentionSystem`, seventeen for `DefaultAttentionSystem`).

  Most of Monty's `DefaultAttentionSystem` cases replace one collaborator with a
  `MagicMock` and assert *that it was called*, with what. Nothing here is called
  behind the caller's back — `step/3` is written out as a pipeline — so those
  cases translate into what the call was protecting: the grid a step produces,
  and what the telemetry recorded. `Monty.Attention.Telemetry.DefaultAttentionSystemTelemetry`
  is the recording double in their place.

  Where Monty's case drives a private method, the case here drives `step/3`, the
  nearest public entry point: `_voxelize_attention_regions` is `attention_grid/2`
  here, private, and its four cases are read off the proposed grid that `step/3`
  hands to the telemetry.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Attention.AttentionSystem.{DefaultAttentionSystem, NoopAttentionSystem}
  alias Monty.Attention.Decay.LinearWeightDecay
  alias Monty.Attention.GoalFilter.NoopGoalFilter
  alias Monty.Attention.Telemetry
  alias Monty.Attention.VoxelGrid
  alias Monty.Cmp.{AttentionRegion, Goal}

  # Places a region at the centre of a voxel of the given size.
  defp centre({x, y, z}, voxel_size),
    do: [(x + 0.5) * voxel_size, (y + 0.5) * voxel_size, (z + 0.5) * voxel_size]

  defp region(places, voxel_size \\ 1.0) do
    %AttentionRegion{
      locations: Enum.map(places, fn {voxel, _weight} -> centre(voxel, voxel_size) end),
      weights: Enum.map(places, &elem(&1, 1))
    }
  end

  defp goal_at(location) do
    {:ok, goal} = Goal.new(%{sender_id: "attention-test", sender_type: :gsg, location: location})
    goal
  end

  defp recording_system(grid, options \\ []) do
    options =
      Keyword.merge(
        [voxel_size: VoxelGrid.voxel_size(grid), telemetry: Telemetry.default()],
        options
      )

    %{DefaultAttentionSystem.new(options) | grid: grid}
  end

  defp telemetry_of(system), do: DefaultAttentionSystem.state_dict(system).telemetry

  describe "NoopAttentionSystem (NoopAttentionSystemTest)" do
    # test_step_does_not_filter_out_any_goals
    property "step does not filter out any goals" do
      check all(
              goals <-
                list_of(member_of([goal_at([0.5, 0.5, 0.5]), goal_at([-3.0, 0.0, 0.0])]),
                  max_length: 4
                )
            ) do
        {_system, kept} =
          NoopAttentionSystem.step(%NoopAttentionSystem{}, goals, [region([{{0, 0, 0}, 0.5}])])

        assert kept == goals
      end
    end

    # test_reset_does_nothing
    property "reset does nothing" do
      check all(
              goals <-
                list_of(member_of([goal_at([0.5, 0.5, 0.5]), goal_at([-3.0, 0.0, 0.0])]),
                  max_length: 4
                )
            ) do
        regions = [region([{{0, 0, 0}, 0.5}])]
        {system, before} = NoopAttentionSystem.step(%NoopAttentionSystem{}, goals, regions)

        {_system, after_reset} =
          NoopAttentionSystem.step(NoopAttentionSystem.reset(system), goals, regions)

        assert after_reset == before
      end
    end

    # test_state_dict_returns_empty_memento
    test "state dict is empty" do
      assert NoopAttentionSystem.state_dict(%NoopAttentionSystem{}) == %{}
    end
  end

  describe "DefaultAttentionSystem.expire/1 (DefaultAttentionSystemTest)" do
    # test_expire_removes_voxels_with_weights_below_weight_expiration_tolerance
    property "drops the voxels whose weight has faded below the tolerance" do
      check all(weights <- list_of(float(min: -1.0, max: 1.0), min_length: 1, max_length: 6)) do
        voxels = weights |> Enum.with_index() |> Enum.map(fn {_, index} -> {index, 0, 0} end)
        expired = DefaultAttentionSystem.expire(VoxelGrid.new(1.0, voxels, weights))

        tolerance = DefaultAttentionSystem.weight_expiration_tolerance()

        assert Enum.all?(VoxelGrid.weights(expired), &(abs(&1) >= tolerance))

        survived = Map.new(Enum.zip(VoxelGrid.voxels(expired), VoxelGrid.weights(expired)))

        for {voxel, weight} <- Enum.zip(voxels, weights), abs(weight) >= tolerance do
          assert survived[voxel] == weight
        end

        assert VoxelGrid.voxel_size(expired) == 1.0
      end
    end
  end

  describe "DefaultAttentionSystem.step/3 reading the proposed regions" do
    # test_voxelize_attention_regions_concatenates_regions
    property "takes the voxels of every region in the step" do
      check all(
              voxels_a <- uniq_list_of(integer(0..50), min_length: 1, max_length: 3),
              voxels_b <- uniq_list_of(integer(51..100), min_length: 1, max_length: 3)
            ) do
        regions = [
          region(Enum.map(voxels_a, &{{&1, 0, 0}, 0.5})),
          region(Enum.map(voxels_b, &{{&1, 0, 0}, 0.5}))
        ]

        system = recording_system(VoxelGrid.empty(1.0))
        {system, _goals} = DefaultAttentionSystem.step(system, [], regions)

        expected = Enum.sort(Enum.map(voxels_a ++ voxels_b, &{&1, 0, 0}))
        assert [proposed] = telemetry_of(system).proposed_grids
        assert VoxelGrid.voxels(proposed) == expected
      end
    end

    # test_voxelize_attention_regions_concatenates_regions_returns_empty_voxel_grid_when_concatenated_region_is_empty
    test "an empty region gives an empty grid, not a voxel of nothing" do
      system = recording_system(VoxelGrid.empty(1.0))

      {system, _goals} = DefaultAttentionSystem.step(system, [], [])

      assert [proposed] = telemetry_of(system).proposed_grids
      assert VoxelGrid.size(proposed) == 0
    end

    # test_voxelize_attention_regions_voxelizes_and_bins_points_when_concatenated_region_is_not_empty
    property "bins each location into its own voxel" do
      check all(
              voxel_size <- float(min: 0.001, max: 1.0),
              voxels <- uniq_list_of(integer(0..20), min_length: 1, max_length: 4)
            ) do
        places = Enum.map(voxels, &{{&1, 0, 0}, 0.5})
        system = recording_system(VoxelGrid.empty(voxel_size))

        {system, _goals} = DefaultAttentionSystem.step(system, [], [region(places, voxel_size)])

        assert [proposed] = telemetry_of(system).proposed_grids
        assert VoxelGrid.voxels(proposed) == Enum.sort(Enum.map(voxels, &{&1, 0, 0}))
      end
    end

    # test_voxelize_attention_regions_pools_weights
    test "pools every weight about one voxel into one" do
      # Two locations in the same voxel: the pooler takes the maximum when
      # nothing is negative, and the most negative when something is.
      voxel = {0, 0, 0}
      system = recording_system(VoxelGrid.empty(1.0))

      {agreeing_system, _goals} =
        DefaultAttentionSystem.step(system, [], [region([{voxel, 0.2}, {voxel, 0.8}])])

      assert [agreeing] = telemetry_of(agreeing_system).proposed_grids
      assert VoxelGrid.weights(agreeing) == [0.8]

      {disagreeing_system, _goals} =
        DefaultAttentionSystem.step(system, [], [region([{voxel, -0.5}, {voxel, 0.3}])])

      assert [disagreeing] = telemetry_of(disagreeing_system).proposed_grids
      assert VoxelGrid.weights(disagreeing) == [-0.5]
    end

    # test_voxelize_attention_regions_creates_voxel_grid
    test "builds the grid at the system's own voxel size" do
      system = recording_system(VoxelGrid.empty(0.25))

      {system, _goals} =
        DefaultAttentionSystem.step(system, [], [region([{{0, 0, 0}, 0.5}], 0.25)])

      assert [proposed] = telemetry_of(system).proposed_grids
      assert VoxelGrid.voxel_size(proposed) == 0.25
    end
  end

  describe "DefaultAttentionSystem.step/3 ordering" do
    # test_step_voxelizes_attention_regions and
    # test_step_updates_telemetry_with_proposed_grid
    test "records the proposed grid apart from the merged one" do
      initial = VoxelGrid.new(1.0, [{0, 0, 0}], [0.5])
      system = recording_system(initial)

      {system, _goals} = DefaultAttentionSystem.step(system, [], [region([{{5, 0, 0}, 0.5}])])

      telemetry = telemetry_of(system)
      assert [proposed] = telemetry.proposed_grids
      assert [kept] = telemetry.grids
      assert VoxelGrid.voxels(proposed) == [{5, 0, 0}]
      assert VoxelGrid.voxels(kept) == [{0, 0, 0}, {5, 0, 0}]
    end

    # test_step_decays_current_grid
    test "decays what it already knew before looking" do
      system =
        recording_system(VoxelGrid.new(1.0, [{0, 0, 0}], [0.5]),
          decay: LinearWeightDecay.new(0.1)
        )

      {system, _goals} = DefaultAttentionSystem.step(system, [], [])

      assert_in_delta hd(VoxelGrid.weights(system.grid)), 0.4, 1.0e-12
    end

    # test_step_expires_current_grid
    test "a weight that decays to zero is dropped rather than kept at nothing" do
      system =
        recording_system(VoxelGrid.new(1.0, [{0, 0, 0}], [0.05]),
          decay: LinearWeightDecay.new(0.1)
        )

      {system, _goals} = DefaultAttentionSystem.step(system, [], [])

      assert VoxelGrid.size(system.grid) == 0
    end

    # test_step_merges_current_grid_with_proposed_grid
    test "merges the proposal into what it knew, the proposal winning where they meet" do
      system = recording_system(VoxelGrid.new(1.0, [{0, 0, 0}], [0.5]))

      {system, _goals} =
        DefaultAttentionSystem.step(system, [], [region([{{0, 0, 0}, 1.0}, {{1, 0, 0}, 0.25}])])

      assert VoxelGrid.weights_at_points(system.grid, [[0.5, 0.5, 0.5], [1.5, 0.5, 0.5]]) == [
               1.0,
               0.25
             ]
    end

    # test_step_updates_telemetry_with_merged_grid
    test "records the merged grid, which is the one it keeps" do
      system = recording_system(VoxelGrid.empty(1.0))

      {system, _goals} = DefaultAttentionSystem.step(system, [], [region([{{0, 0, 0}, 0.5}])])

      assert telemetry_of(system).grids == [system.grid]
    end

    # test_step_returns_filtered_goals
    test "answers the goals the goal filter kept" do
      # Voxel {0,0,0} is inhibited, {1,0,0} is not: the goal in {0,0,0} is dropped.
      system = recording_system(VoxelGrid.new(1.0, [{0, 0, 0}, {1, 0, 0}], [-1.0, 1.0]))
      kept = goal_at([1.5, 0.5, 0.5])
      dropped = goal_at([0.5, 0.5, 0.5])

      {_system, goals} = DefaultAttentionSystem.step(system, [dropped, kept], [])

      assert goals == [kept]
    end
  end

  describe "DefaultAttentionSystem reset and state dict" do
    # test_reset_sets_grid_to_empty
    property "reset empties the grid" do
      check all(voxels <- uniq_list_of(integer(0..10), min_length: 1, max_length: 4)) do
        grid =
          VoxelGrid.new(1.0, Enum.map(voxels, &{&1, 0, 0}), List.duplicate(0.5, length(voxels)))

        assert VoxelGrid.size(DefaultAttentionSystem.reset(recording_system(grid)).grid) == 0
      end
    end

    # test_reset_resets_telemetry
    test "reset empties the telemetry" do
      system = recording_system(VoxelGrid.empty(1.0))
      {system, _goals} = DefaultAttentionSystem.step(system, [], [region([{{0, 0, 0}, 0.5}])])

      assert telemetry_of(DefaultAttentionSystem.reset(system)) == %{
               grids: [],
               proposed_grids: []
             }
    end

    # test_state_dict_returns_current_grid
    test "the state dict carries the current grid" do
      system = recording_system(VoxelGrid.new(1.0, [{0, 0, 0}], [0.5]))

      assert DefaultAttentionSystem.state_dict(system).grid == system.grid
    end

    # test_state_dict_returns_telemetry_state_dict
    test "the state dict carries the telemetry's state dict" do
      system = recording_system(VoxelGrid.empty(1.0))
      {system, _goals} = DefaultAttentionSystem.step(system, [], [region([{{0, 0, 0}, 0.5}])])

      assert DefaultAttentionSystem.state_dict(system).telemetry ==
               Monty.Attention.Telemetry.DefaultAttentionSystemTelemetry.state_dict(
                 system.telemetry
               )
    end
  end

  describe "DefaultAttentionSystem collaborators" do
    test "a goal filter that keeps everything is what NoopGoalFilter is for" do
      system =
        recording_system(VoxelGrid.new(1.0, [{0, 0, 0}], [-1.0]),
          goal_filter: &NoopGoalFilter.filter/2
        )

      goal = goal_at([0.5, 0.5, 0.5])

      {_system, goals} = DefaultAttentionSystem.step(system, [goal], [])

      assert goals == [goal]
    end
  end
end
