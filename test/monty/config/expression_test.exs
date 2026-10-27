defmodule Monty.Config.ExpressionTest do
  use ExUnit.Case, async: true

  alias Monty.Config.Expression

  describe "evaluate/1" do
    test "evaluates the arithmetic Monty writes in np.list_eval entries" do
      assert Expression.evaluate("[np.pi / 8, np.pi * 2, np.pi * 2]") ==
               {:ok, [:math.pi() / 8, :math.pi() * 2, :math.pi() * 2]}
    end

    test "multiplies before it adds, and parentheses win" do
      assert Expression.evaluate("1 + 2 * 3") == {:ok, 7.0}
      assert Expression.evaluate("(1 + 2) * 3") == {:ok, 9.0}
    end

    test "reads a plain list of numbers" do
      assert Expression.evaluate("[2, 0.5, 0.5]") == {:ok, [2.0, 0.5, 0.5]}
    end

    test "handles a leading minus" do
      assert Expression.evaluate("[-np.pi, 2]") == {:ok, [-:math.pi(), 2.0]}
    end

    test "refuses to divide by zero rather than crashing the resolver" do
      assert Expression.evaluate("1 / 0") == {:error, :division_by_zero}
    end

    test "refuses anything outside its grammar" do
      assert {:error, {:unexpected_input, _rest}} = Expression.evaluate("__import__('os')")
      assert Expression.evaluate("[1, 2") == {:error, {:expected_comma_or_bracket, []}}
    end
  end
end
