defmodule Monty.Geometry.LinearAlgebraTest do
  @moduledoc """
  The two routines a sensor's fits are made of: solving a small linear system,
  and the eigendecomposition of a small matrix.

  Every assertion is the defining property rather than a number read off an
  implementation: a solution satisfies the equation it solves, and an
  eigenpair satisfies `A v = λ v`.
  """

  use ExUnit.Case, async: true

  alias Monty.Geometry.LinearAlgebra

  describe "solving a linear system" do
    test "answers the vector the equation asked for" do
      # 2x + y = 5, x + 3y = 10.
      assert {:ok, [x, y]} = LinearAlgebra.solve([[2.0, 1.0], [1.0, 3.0]], [5.0, 10.0])

      assert_in_delta 2.0 * x + y, 5.0, 1.0e-12
      assert_in_delta x + 3.0 * y, 10.0, 1.0e-12
    end

    test "and pivots, so a zero in the first row is not the end of it" do
      # The first column's largest entry is in the second row.
      assert {:ok, [x, y]} = LinearAlgebra.solve([[1.0e-18, 1.0], [1.0, 1.0]], [1.0, 2.0])

      assert_in_delta x, 1.0, 1.0e-6
      assert_in_delta y, 1.0, 1.0e-6
    end

    test "and works at the size a quadratic fit needs" do
      # Six unknowns, the shape of `principal_curvatures`' fit: a system whose
      # exact answer is [1, 2, 3, 4, 5, 6].
      matrix = [
        [4.0, 1.0, -2.0, 2.0, 0.0, 0.0],
        [1.0, 3.0, 0.0, 1.0, 1.0, 0.0],
        [-2.0, 0.0, 5.0, 0.0, 0.0, 2.0],
        [2.0, 1.0, 0.0, 6.0, -1.0, 0.0],
        [0.0, 1.0, 0.0, -1.0, 7.0, 1.0],
        [0.0, 0.0, 2.0, 0.0, 1.0, 8.0]
      ]

      expected = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]

      right =
        Enum.map(matrix, fn row ->
          Enum.zip_with([row, expected], fn [a, b] -> a * b end) |> Enum.sum()
        end)

      assert {:ok, solved} = LinearAlgebra.solve(matrix, right)

      expected
      |> Enum.zip(solved)
      |> Enum.each(fn {want, got} -> assert_in_delta got, want, 1.0e-9 end)
    end

    test "and a matrix with no solution says so rather than answering NaNs" do
      assert LinearAlgebra.solve([[1.0, 2.0], [2.0, 4.0]], [3.0, 6.0]) == :singular
    end
  end

  describe "the eigenpairs of a symmetric matrix" do
    test "are the ones that satisfy A v = lambda v" do
      matrix = [[2.0, 1.0], [1.0, 2.0]]

      assert [{first, first_vector}, {second, second_vector}] =
               LinearAlgebra.symmetric_eigen(matrix)

      assert_in_delta first, 1.0, 1.0e-12
      assert_in_delta second, 3.0, 1.0e-12
      assert_eigenpair(matrix, first, first_vector)
      assert_eigenpair(matrix, second, second_vector)
    end

    test "and come out ascending, so the smallest is first" do
      matrix = [[4.0, 0.0, 0.0], [0.0, -1.0, 0.0], [0.0, 0.0, 9.0]]

      assert [{first, _}, {second, _}, {third, _}] = LinearAlgebra.symmetric_eigen(matrix)

      assert_in_delta first, -1.0, 1.0e-12
      assert_in_delta second, 4.0, 1.0e-12
      assert_in_delta third, 9.0, 1.0e-12
    end

    test "and a matrix that is not diagonal has eigenvectors too" do
      # The covariance of a tilted patch of points: symmetric, with a direction
      # of least spread that is the normal a sensor is looking for.
      matrix = [[3.0, 1.0, 0.5], [1.0, 2.0, 0.25], [0.5, 0.25, 1.0]]

      LinearAlgebra.symmetric_eigen(matrix)
      |> Enum.each(fn {value, vector} -> assert_eigenpair(matrix, value, vector) end)
    end

    test "and the directions are unit vectors that are square to each other" do
      matrix = [[3.0, 1.0, 0.5], [1.0, 2.0, 0.25], [0.5, 0.25, 1.0]]

      [first, second, third] =
        matrix |> LinearAlgebra.symmetric_eigen() |> Enum.map(&elem(&1, 1))

      for vector <- [first, second, third] do
        assert_in_delta Enum.sum(Enum.map(vector, &(&1 * &1))), 1.0, 1.0e-12
      end

      assert_in_delta dot(first, second), 0.0, 1.0e-12
      assert_in_delta dot(first, third), 0.0, 1.0e-12
      assert_in_delta dot(second, third), 0.0, 1.0e-12
    end
  end

  describe "the eigenpairs of a two-by-two matrix" do
    test "are the ones that satisfy M v = lambda v, largest first" do
      matrix = [[4.0, 1.0], [2.0, 3.0]]

      assert [{largest, largest_vector}, {smallest, smallest_vector}] =
               LinearAlgebra.eigen_2x2(matrix)

      assert_in_delta largest, 5.0, 1.0e-12
      assert_in_delta smallest, 2.0, 1.0e-12
      assert_eigenpair(matrix, largest, largest_vector)
      assert_eigenpair(matrix, smallest, smallest_vector)
    end

    test "and a repeated eigenvalue answers two directions, as numpy does" do
      # A sphere's shape operator is the identity times its curvature: every
      # direction is a principal one, so the answer has to be two directions
      # rather than the same one twice.
      matrix = [[-20.0, 0.0], [0.0, -20.0]]

      assert [{-20.0, first}, {-20.0, second}] = LinearAlgebra.eigen_2x2(matrix)

      assert_in_delta dot(first, first), 1.0, 1.0e-12
      assert_in_delta dot(second, second), 1.0, 1.0e-12
      assert_in_delta dot(first, second), 0.0, 1.0e-12
    end
  end

  defp assert_eigenpair(matrix, value, vector) do
    product = Enum.map(matrix, fn row -> dot(row, vector) end)

    product
    |> Enum.zip(vector)
    |> Enum.each(fn {got, component} -> assert_in_delta got, value * component, 1.0e-9 end)
  end

  defp dot(left, right), do: Enum.zip_with([left, right], fn [a, b] -> a * b end) |> Enum.sum()
end
