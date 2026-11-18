defmodule Monty.MathTest do
  use ExUnit.Case, async: true

  alias Monty.Math

  # numpy's answer, not Elixir's: the sum of a sample holding a NaN is a NaN, and
  # this port's marker for one is `nil` — the value a kernel's column reads back
  # for the NaN bits, and what a node the features could not score carries.
  # Elixir's own sum raises on the `nil`, which took a learning module down.
  describe "summarising a sample" do
    test "averages the numbers" do
      assert Math.mean([1.0, 2.0, 3.0]) == 2.0
      assert Math.mean([]) == 0.0
    end

    test "has no average when one value is not a number" do
      assert Math.mean([1.0, nil]) == nil
      assert Math.population_std([1.0, nil]) == nil
    end

    test "spreads around the average by the population's own divisor" do
      assert Math.population_std([1.0, 3.0]) == 1.0
    end
  end
end
