defmodule Monty.Frameworks.Utils.SpatialArithmetics.TangentFrameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Frameworks.Utils.SpatialArithmetics.TangentFrame
  alias Monty.Math

  import SpatialArithmetics, only: [cross: 2, dot: 2, magnitude: 1, normalize: 1]

  @tolerance Math.default_tolerance()

  defp unit_vector_generator do
    gen all(
          x <- StreamData.float(min: -1.0, max: 1.0),
          y <- StreamData.float(min: -1.0, max: 1.0),
          z <- StreamData.float(min: -1.0, max: 1.0),
          magnitude([x, y, z]) > 0.05
        ) do
      normalize([x, y, z])
    end
  end

  defp assert_orthonormal_frame(%TangentFrame{} = frame) do
    u = TangentFrame.basis_u(frame)
    v = TangentFrame.basis_v(frame)
    n = TangentFrame.normal(frame)

    for vector <- [u, v, n] do
      assert_in_delta magnitude(vector), 1.0, @tolerance
    end

    assert_in_delta dot(u, v), 0.0, @tolerance
    assert_in_delta dot(u, n), 0.0, @tolerance
    assert_in_delta dot(v, n), 0.0, @tolerance

    assert_vectors_match(cross(u, v), n)
    assert_vectors_match(cross(v, u), Enum.map(n, &(-1.0 * &1)))
  end

  describe "new/1" do
    property "gives a right-handed orthonormal frame on the normal" do
      check all(normal <- unit_vector_generator()) do
        frame = TangentFrame.new(normal)

        assert_vectors_match(TangentFrame.normal(frame), normal)
        assert_orthonormal_frame(frame)
      end
    end

    test "for the axis-aligned normals, where the arbitrary axis is parallel to the normal" do
      for normal <- [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]] do
        frame = TangentFrame.new(normal)

        assert_vectors_match(TangentFrame.normal(frame), normal)
        assert_orthonormal_frame(frame)
      end
    end

    test "the normal is normalised for us" do
      frame = TangentFrame.new([0.0, 0.0, 5.0])

      assert_vectors_match(TangentFrame.normal(frame), [0.0, 0.0, 1.0])
    end
  end

  describe "transport/2" do
    property "to the same normal changes nothing" do
      check all(normal <- unit_vector_generator()) do
        frame = TangentFrame.new(normal)
        transported = TangentFrame.transport(frame, normal)

        assert_vectors_match(TangentFrame.basis_u(transported), TangentFrame.basis_u(frame))
        assert_vectors_match(TangentFrame.basis_v(transported), TangentFrame.basis_v(frame))
      end
    end

    property "to any other normal keeps the frame orthonormal" do
      check all(normal <- unit_vector_generator(), new_normal <- unit_vector_generator()) do
        transported = normal |> TangentFrame.new() |> TangentFrame.transport(new_normal)

        assert_vectors_match(TangentFrame.normal(transported), new_normal)
        assert_orthonormal_frame(transported)
      end
    end

    test "to the opposite normal keeps the frame orthonormal" do
      transported =
        [1.0, 0.0, 0.0]
        |> TangentFrame.new()
        |> TangentFrame.transport([-1.0, 0.0, 0.0])

      assert_orthonormal_frame(transported)
    end

    test "a thousand steps over a curved surface do not drift out of the tangent plane" do
      :rand.seed(:exsss, {42, 42, 42})
      start = normalize(random_direction())

      {frame, final_normal} =
        Enum.reduce(1..1000, {TangentFrame.new(start), start}, fn _step, {frame, normal} ->
          new_normal = normal |> perturb() |> normalize()

          {TangentFrame.transport(frame, new_normal), new_normal}
        end)

      assert_vectors_match(TangentFrame.normal(frame), final_normal)
      assert_orthonormal_frame(frame)
    end
  end

  defp assert_vectors_match(left, right, tolerance \\ @tolerance) do
    Enum.zip(left, right)
    |> Enum.each(fn {l, r} -> assert_in_delta l, r, tolerance end)
  end

  defp random_direction, do: Enum.map(1..3, fn _component -> :rand.normal() end)

  defp perturb(vector), do: Enum.map(vector, &(&1 + 0.05 * :rand.normal()))
end
