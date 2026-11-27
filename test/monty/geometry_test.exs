defmodule Monty.GeometryTest do
  use ExUnit.Case, async: true

  alias Monty.Geometry
  alias Monty.Geometry.Rotation

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

  # Monty's `ScipyRotationsApproxEqualTest`: the comparison the model uses to
  # decide whether two rotations are the same one. scipy compares the angle of
  # `a · b⁻¹` with the tolerance; `rotations_approx_equal?/3` compares the two
  # quaternions' dot product, and the cases below are the double ledger between
  # the two routes.
  describe "rotations_approx_equal?/3" do
    @tolerance 1.0e-6
    # Monty's `ROTATION_EXAMPLE_ERROR`: a rotation built to a given angle is
    # accurate to about this much, so a case that sits this close to the
    # tolerance cannot say which side of it it is on.
    @example_error 1.0e-15

    # test_returns_true_if_delta_below_tolerance
    test "a turn smaller than the tolerance is the same rotation" do
      for base <- [Rotation.identity(), turned(:z, 1.2), turned(:x, -0.7)],
          angle <- [0.0, @tolerance / 2, @tolerance - @example_error] do
        assert Geometry.rotations_approx_equal?(base, turn(base, :y, angle)),
               "a turn of #{angle} should be the same rotation"
      end
    end

    # test_returns_all_true_if_all_deltas_below_tolerance_for_multiple_rotations
    test "and so is every one of several" do
      bases = for k <- 1..10, do: turned(:z, k / 10)
      angles = [0.0, @tolerance / 4, @tolerance - @example_error]

      for base <- bases, angle <- angles do
        assert Geometry.rotations_approx_equal?(base, turn(base, :x, angle)),
               "a turn of #{angle} should be the same rotation"
      end
    end

    # test_returns_false_if_delta_above_tolerance
    test "a turn larger than the tolerance is a different rotation" do
      for base <- [Rotation.identity(), turned(:z, 1.2), turned(:x, -0.7)],
          angle <- [@tolerance + @example_error, 2 * @tolerance] do
        relative = relative_angle(base, turn(base, :y, angle))

        refute Geometry.rotations_approx_equal?(base, turn(base, :y, angle)),
               "a turn of #{angle} (relative #{relative}) should be different"
      end
    end

    # test_returns_all_false_if_all_deltas_above_tolerance_for_multiple_rotations
    test "and every one of several turned too far is a different one" do
      bases = for k <- 1..10, do: turned(:z, k / 10)
      angles = [@tolerance + @example_error, 2 * @tolerance]

      for base <- bases, angle <- angles do
        refute Geometry.rotations_approx_equal?(base, turn(base, :x, angle)),
               "a turn of #{angle} should be different"
      end
    end

    # test_against_alternate_implementation_over_full_range
    test "agrees with the angle of the relative rotation, whatever the pair" do
      pairs =
        for a <- [Rotation.identity(), turned(:z, 2.4), turned(:x, -1.1)],
            b <- [Rotation.identity(), turned(:y, 0.3), turned(:z, -2.0)],
            do: {a, b}

      for {a, b} <- pairs do
        angle = relative_angle(a, b)

        assert Geometry.rotations_approx_equal?(a, b) == angle <= @tolerance
      end
    end

    # test_against_alternate_implementation_near_boundary
    test "and agrees around the boundary, where the two routes could part" do
      for base <- [Rotation.identity(), turned(:z, 0.8), turned(:x, 2.2)],
          factor <- [0.9, 0.99, 1.01, 1.1] do
        angle = @tolerance * factor
        other = turn(base, :y, angle)
        relative = relative_angle(base, other)

        # A pair that sits on the boundary cannot say which side it is on, so
        # Monty's case skips it rather than flipping a coin.
        if abs(relative - @tolerance) > 1.0e-14 do
          assert Geometry.rotations_approx_equal?(base, other) == relative <= @tolerance
        end
      end
    end
  end

  defp turned(axis, radians) do
    {:ok, rotation} = Rotation.from_axis_angle(axis_vector(axis), radians)
    rotation
  end

  defp turn(rotation, axis, radians) do
    axis = axis_vector(axis)
    {:ok, extra} = Rotation.from_axis_angle(axis, radians)
    Rotation.multiply(rotation, extra)
  end

  defp axis_vector(:x), do: [1.0, 0.0, 0.0]
  defp axis_vector(:y), do: [0.0, 1.0, 0.0]
  defp axis_vector(:z), do: [0.0, 0.0, 1.0]

  # scipy's route: the angle of `a · b⁻¹`.
  defp relative_angle(left, right) do
    left |> Rotation.multiply(Rotation.invert(right)) |> Rotation.magnitude()
  end
end
