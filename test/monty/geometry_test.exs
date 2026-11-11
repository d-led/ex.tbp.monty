defmodule Monty.GeometryTest do
  use ExUnit.Case, async: true

  alias Monty.Geometry

  describe "identity/0" do
    test "leaves a vector alone when applied" do
      assert Geometry.apply(Geometry.identity(), [1.0, 2.0, 3.0]) == [1.0, 2.0, 3.0]
    end
  end

  describe "mul/2" do
    test "composes a rotation about z by ninety degrees with itself into a half turn" do
      quarter_turn = [[0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]]

      assert Geometry.mul(quarter_turn, quarter_turn) == [
               [-1.0, 0.0, 0.0],
               [0.0, -1.0, 0.0],
               [0.0, 0.0, 1.0]
             ]
    end

    test "is not commutative, so the order of a left and a right factor matters" do
      turn = [[0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]]
      flip = [[1.0, 0.0, 0.0], [0.0, -1.0, 0.0], [0.0, 0.0, -1.0]]

      refute Geometry.mul(turn, flip) == Geometry.mul(flip, turn)
    end

    # The product is nine multiplications written out, and rotations composed with
    # themselves hide a transposed index (`mul(t, t)` is symmetric for a rotation
    # like that). What makes the write-out right is the definition it came from:
    # element (i, j) is row i of the left factor dotted with column j of the
    # right, which is what `numpy.dot` means.
    test "each element is a row of the left factor dotted with a column of the right" do
      left = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 10.0]]
      right = [[1.0, 0.0, 2.0], [0.0, 3.0, 1.0], [2.0, 1.0, 0.0]]

      product =
        for row <- left do
          for column <- Geometry.transpose(right), do: Geometry.dot(row, column)
        end

      assert Geometry.mul(left, right) == product
    end
  end

  describe "transpose/1" do
    test "turns rows into columns" do
      assert Geometry.transpose([[1, 2, 3], [4, 5, 6], [7, 8, 9]]) ==
               [[1, 4, 7], [2, 5, 8], [3, 6, 9]]
    end
  end

  describe "vector arithmetic" do
    test "adds, subtracts and dots three-vectors" do
      assert Geometry.add([1.0, 2.0, 3.0], [4.0, 5.0, 6.0]) == [5.0, 7.0, 9.0]
      assert Geometry.subtract([1.0, 2.0, 3.0], [1.0, 1.0, 1.0]) == [0.0, 1.0, 2.0]
      assert Geometry.dot([1.0, 2.0, 3.0], [4.0, 5.0, 6.0]) == 32.0
    end
  end
end
