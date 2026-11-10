defmodule Monty.Attention.DecayTest do
  @moduledoc """
  Translations of `tests/unit/attention/decay_test.py`.

  Monty's `LinearWeightDecay.__call__` decays the grid in place; here it answers
  a decayed grid, so each case reads the result instead of the argument.

  `VoxelGridWeightDecay` (the one-method `Protocol`) has no case of its own in
  Monty — it has no body to test — and here it is the `decay/2` behaviour both
  implementations adopt.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Attention.Decay.{LinearWeightDecay, NoopDecay}
  alias Monty.Attention.VoxelGrid

  # Monty's `LinearWeightDecayTest` bounds for the rate.
  @min_rate 1.0e-6
  @max_rate 10.0

  defp grid_with_weights(weights) do
    voxels = weights |> Enum.with_index() |> Enum.map(fn {_, index} -> {index, 0, 0} end)
    VoxelGrid.new(1.0, voxels, weights)
  end

  describe "NoopDecay (NoopDecayTest)" do
    # test_the_grid_is_left_unchanged
    property "the grid is left unchanged" do
      check all(weights <- list_of(float(min: -1.0, max: 1.0), min_length: 1, max_length: 6)) do
        grid = grid_with_weights(weights)

        assert NoopDecay.decay(%NoopDecay{}, grid) == grid
      end
    end
  end

  describe "LinearWeightDecay.new/1 (LinearWeightDecayTest)" do
    # test_raises_value_error_for_negative_rate
    property "refuses a negative rate" do
      check all(rate <- float(min: -@max_rate, max: -@min_rate)) do
        assert_raise ArgumentError, fn -> LinearWeightDecay.new(rate) end
      end
    end
  end

  describe "LinearWeightDecay.decay/2 (LinearWeightDecayTest)" do
    # test_moves_weights_toward_zero_by_the_rate_and_clamps_near_zero
    property "moves weights toward zero by the rate and clamps what is within reach" do
      check all(
              weights <- list_of(float(min: -1.0, max: 1.0), min_length: 1, max_length: 8),
              rate <- float(min: @min_rate, max: @max_rate)
            ) do
        grid = grid_with_weights(weights)
        decayed = LinearWeightDecay.decay(LinearWeightDecay.new(rate), grid)

        assert VoxelGrid.voxels(decayed) == VoxelGrid.voxels(grid)

        for {before_weight, after_weight} <-
              Enum.zip(VoxelGrid.weights(grid), VoxelGrid.weights(decayed)) do
          cond do
            before_weight < -rate -> assert_in_delta(after_weight, before_weight + rate, 1.0e-12)
            abs(before_weight) <= rate -> assert after_weight == 0.0
            true -> assert_in_delta(after_weight, before_weight - rate, 1.0e-12)
          end
        end
      end
    end

    # Monty's `__call__` returns early when `self._rate == 0.0`; the guard is the
    # specification of what a zero rate means.
    test "a rate of zero leaves every weight untouched" do
      grid = grid_with_weights([0.5, -0.25, 0.0])

      assert LinearWeightDecay.decay(LinearWeightDecay.new(0.0), grid) == grid
    end
  end
end
