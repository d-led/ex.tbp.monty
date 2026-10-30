defmodule Monty.Geometry.RotationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Geometry.Rotation

  @tolerance 1.0e-6

  defp vector_generator do
    gen all(
          x <- StreamData.float(min: -1.0, max: 1.0),
          y <- StreamData.float(min: -1.0, max: 1.0),
          z <- StreamData.float(min: -1.0, max: 1.0),
          magnitude = :math.sqrt(x * x + y * y + z * z),
          magnitude > 0.1
        ) do
      [x, y, z]
    end
  end

  defp rotation_generator do
    gen all(axis <- vector_generator(), angle <- StreamData.float(min: 0.0, max: :math.pi())) do
      {:ok, rotation} = Rotation.from_axis_angle(axis, angle)
      rotation
    end
  end

  defp length_of([x, y, z]), do: :math.sqrt(x * x + y * y + z * z)

  defp dot([a1, a2, a3], [b1, b2, b3]), do: a1 * b1 + a2 * b2 + a3 * b3

  describe "identity/0" do
    test "leaves a vector where it is" do
      assert Rotation.apply(Rotation.identity(), [1.0, -2.0, 3.0]) == [1.0, -2.0, 3.0]
    end

    test "turns through no angle" do
      assert Rotation.magnitude(Rotation.identity()) == 0.0
    end
  end

  describe "from_axis_angle/2" do
    test "a quarter turn about z takes +x to +y" do
      {:ok, rotation} = Rotation.from_axis_angle([0.0, 0.0, 1.0], :math.pi() / 2)

      assert [x, y, _z] = Rotation.apply(rotation, [1.0, 0.0, 0.0])
      assert_in_delta x, 0.0, @tolerance
      assert_in_delta y, 1.0, @tolerance
    end

    test "a zero axis describes no rotation" do
      assert Rotation.from_axis_angle([0.0, 0.0, 0.0], 1.0) == {:error, :zero_axis}
    end

    property "the angle it reports is the angle it was given" do
      check all(angle <- StreamData.float(min: 0.0, max: :math.pi()), max_runs: 20) do
        {:ok, rotation} = Rotation.from_axis_angle([1.0, 2.0, 3.0], angle)

        assert_in_delta Rotation.magnitude(rotation), angle, @tolerance
      end
    end

    property "it preserves lengths" do
      check all(rotation <- rotation_generator(), vector <- vector_generator(), max_runs: 20) do
        assert_in_delta length_of(Rotation.apply(rotation, vector)), length_of(vector), @tolerance
      end
    end
  end

  describe "to_matrix/1" do
    property "is orthonormal with a determinant of one" do
      check all(rotation <- rotation_generator(), max_runs: 20) do
        [u, v, n] = Rotation.to_matrix(rotation)

        Enum.each([u, v, n], fn row -> assert_in_delta length_of(row), 1.0, @tolerance end)
        assert_in_delta dot(u, v), 0.0, @tolerance
        assert_in_delta dot(u, n), 0.0, @tolerance
        assert_in_delta dot(v, n), 0.0, @tolerance

        assert_in_delta dot(u, cross(v, n)), 1.0, @tolerance
      end
    end

    property "a rotation survives a trip through its matrix" do
      check all(rotation <- rotation_generator(), vector <- vector_generator(), max_runs: 20) do
        {:ok, rebuilt} = rotation |> Rotation.to_matrix() |> Rotation.from_matrix()

        assert_vectors_match(Rotation.apply(rebuilt, vector), Rotation.apply(rotation, vector))
      end
    end
  end

  describe "invert/1" do
    property "undoes the rotation" do
      check all(rotation <- rotation_generator(), vector <- vector_generator(), max_runs: 20) do
        restored =
          rotation
          |> Rotation.apply(vector)
          |> then(&Rotation.apply(Rotation.invert(rotation), &1))

        assert_vectors_match(restored, vector)
      end
    end
  end

  describe "from_euler_degrees/1" do
    property "reads back the angles it was built from" do
      check all(
              rx <- StreamData.float(min: -80.0, max: 80.0),
              ry <- StreamData.float(min: -80.0, max: 80.0),
              rz <- StreamData.float(min: -80.0, max: 80.0),
              max_runs: 20
            ) do
        {:ok, rotation} = Rotation.from_euler_degrees([rx, ry, rz])

        assert [x, y, z] = Rotation.to_euler_degrees(rotation)
        assert_in_delta x, rx, 0.001
        assert_in_delta y, ry, 0.001
        assert_in_delta z, rz, 0.001
      end
    end

    test "a quarter turn answers its angles instead of an arithmetic error" do
      # The matrix of a 90° turn gives sin(ry) as 1.0000000000000002, and asin
      # refuses anything past one. scipy clamps, and a pose at ninety degrees is
      # a pose: this is what a policy asks for when it sets a sensor straight
      # up, so it must answer rather than raise.
      {:ok, rotation} = Rotation.from_euler_degrees([0.0, 90.0, 0.0])

      assert [x, y, z] = Rotation.to_euler_degrees(rotation)
      assert_in_delta y, 90.0, 0.001
      assert_in_delta x, 0.0, 0.001
      assert_in_delta z, 0.0, 0.001
    end

    test "x turns first, in the frame the axes were given in" do
      # Extrinsic xyz: 90° about x then 90° about y takes +y to +z to +x.
      {:ok, rotation} = Rotation.from_euler_degrees([90.0, 90.0, 0.0])

      assert [x, y, z] = Rotation.apply(rotation, [0.0, 1.0, 0.0])
      assert_in_delta x, 1.0, @tolerance
      assert_in_delta y, 0.0, @tolerance
      assert_in_delta z, 0.0, @tolerance
    end
  end

  describe "from_quaternion/1" do
    test "a zero quaternion describes no rotation" do
      assert Rotation.from_quaternion({0.0, 0.0, 0.0, 0.0}) == {:error, :zero_quaternion}
    end

    test "keeps the wxyz order, and the xyzw order is what scipy returns" do
      {:ok, rotation} = Rotation.from_quaternion({1.0, 0.0, 0.0, 0.0})

      assert Rotation.to_quaternion(rotation) == {1.0, 0.0, 0.0, 0.0}
      assert Rotation.to_xyzw(rotation) == [0.0, 0.0, 0.0, 1.0]
    end
  end

  defp cross([a1, a2, a3], [b1, b2, b3]) do
    [a2 * b3 - a3 * b2, a3 * b1 - a1 * b3, a1 * b2 - a2 * b1]
  end

  defp assert_vectors_match(left, right) do
    Enum.zip(left, right)
    |> Enum.each(fn {l, r} -> assert_in_delta l, r, @tolerance end)
  end
end
