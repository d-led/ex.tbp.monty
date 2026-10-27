defmodule Monty.Cmp.AttentionRegionTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.AttentionRegion

  describe "empty/0" do
    test "proposes nothing" do
      assert AttentionRegion.empty?(AttentionRegion.empty())
    end
  end

  describe "uniform/2" do
    test "gives every location the same weight" do
      region = AttentionRegion.uniform([[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]], max_weight())

      assert region.locations == [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0]]
      assert region.weights == [max_weight(), max_weight()]
    end

    test "a full-weight region is not empty" do
      refute AttentionRegion.empty?(AttentionRegion.uniform([[0.0, 0.0, 0.0]], max_weight()))
    end
  end

  describe "concat/1" do
    test "joins locations and weights in order" do
      first = AttentionRegion.uniform([[0.0, 0.0, 0.0]], 1.0)
      second = AttentionRegion.uniform([[1.0, 0.0, 0.0], [2.0, 0.0, 0.0]], -0.5)

      assert AttentionRegion.concat([first, second]) == %AttentionRegion{
               locations: [[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [2.0, 0.0, 0.0]],
               weights: [1.0, -0.5, -0.5]
             }
    end

    test "no regions is an empty region" do
      assert AttentionRegion.concat([]) == AttentionRegion.empty()
    end
  end

  defp max_weight, do: AttentionRegion.max_weight()
end
