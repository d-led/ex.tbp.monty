defmodule Monty.Frameworks.Utils.SpatialArithmeticsMontyTest do
  @moduledoc """
  Monty's own cases for the spatial arithmetic, translated.

  Each test names the case in
  `tests/unit/frameworks/utils/spatial_arithmetics_test.py` it translates.
  Monty's cases draw their vectors from hypothesis; here they are fixed vectors,
  including every one Monty pins with an `@example` — the three axis normals for
  the tangent frame, the opposite normal for transport, and the four angle pairs
  (45°, parallel, anti-parallel, orthogonal). A property that holds for a drawn
  vector is a property; the fixed vectors are the ones Monty itself chose to
  check first.

  `normalize` raises `ArgumentError` where Monty's `ValueError` did: a vector
  shorter than the epsilon has no direction to return.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Utils.SpatialArithmetics
  alias Monty.Frameworks.Utils.SpatialArithmetics.TangentFrame

  @tolerance 1.0e-6

  # Vectors with a direction: the ones Monty's generator produces, and the ones
  # its `@example`s name.
  @directions [
    [1.0, 0.0, 0.0],
    [0.0, 1.0, 0.0],
    [0.0, 0.0, -1.0],
    [1.0, 2.0, -3.0],
    [-4.0, 0.5, 6.0]
  ]

  defp close?(left, right, tolerance \\ @tolerance) do
    Enum.zip(List.wrap(left), List.wrap(right))
    |> Enum.all?(fn {a, b} -> abs(a - b) <= tolerance end)
  end

  defp zero?(vector), do: Enum.all?(vector, &(abs(&1) <= @tolerance))

  defp rand_normal, do: :rand.normal()

  # --- normalize ------------------------------------------------------------

  describe "normalize" do
    # test_preserves_direction
    test "the unit vector points the way the vector pointed" do
      for v <- @directions do
        assert close?(
                 SpatialArithmetics.scale(
                   SpatialArithmetics.normalize(v),
                   SpatialArithmetics.magnitude(v)
                 ),
                 v
               )
      end
    end

    # test_idempotent
    test "normalizing a unit vector leaves it alone" do
      for v <- @directions do
        once = SpatialArithmetics.normalize(v)
        assert close?(SpatialArithmetics.normalize(once), once)
      end
    end

    # test_zero_vector_raises
    test "the zero vector has no direction, and is refused" do
      assert_raise ArgumentError, fn -> SpatialArithmetics.normalize([0.0, 0.0, 0.0]) end
    end

    # test_custom_epsilon
    test "a vector shorter than the epsilon is refused" do
      # Monty draws the epsilon and a scale below one, so the vector is always
      # shorter than the epsilon it is measured against.
      epsilon = 1.0e-3
      scale = 0.5

      assert_raise ArgumentError, fn ->
        SpatialArithmetics.normalize([epsilon * scale, 0.0, 0.0], epsilon)
      end
    end

    # test_result_has_unit_norm
    test "the answer is a unit vector" do
      for v <- @directions do
        assert_in_delta SpatialArithmetics.magnitude(SpatialArithmetics.normalize(v)),
                        1.0,
                        @tolerance
      end
    end
  end

  # --- the tangent plane ----------------------------------------------------

  describe "projecting onto the tangent plane" do
    # test_a_vector_parallel_to_normal
    test "a vector along the normal collapses to nothing" do
      for vector <- @directions, scalar <- [-3.0, 0.25, 1.0e3] do
        parallel = SpatialArithmetics.scale(vector, scalar)

        assert zero?(SpatialArithmetics.project_onto_tangent_plane(parallel, vector))
      end
    end

    # test_a_vector_perpendicular_to_normal
    test "a vector already in the plane is unchanged" do
      normal = SpatialArithmetics.normalize([1.0, 2.0, -3.0])
      in_plane = SpatialArithmetics.cross([0.0, 0.0, 1.0], normal)

      assert close?(
               SpatialArithmetics.project_onto_tangent_plane(in_plane, normal),
               in_plane,
               @tolerance * SpatialArithmetics.magnitude(in_plane)
             )
    end

    # test_result_is_orthogonal_to_normal
    test "what is left has no component along the normal" do
      for vector <- @directions, normal <- @directions do
        unit_normal = SpatialArithmetics.normalize(normal)

        projected = SpatialArithmetics.project_onto_tangent_plane(vector, normal)

        assert_in_delta SpatialArithmetics.dot(projected, unit_normal), 0.0, @tolerance
      end
    end

    # test_projection_is_idempotent
    test "projecting again changes nothing" do
      for vector <- @directions, normal <- @directions do
        once = SpatialArithmetics.project_onto_tangent_plane(vector, normal)

        assert close?(
                 SpatialArithmetics.project_onto_tangent_plane(once, normal),
                 once,
                 @tolerance * max(1.0, SpatialArithmetics.magnitude(vector))
               )
      end
    end
  end

  # --- the tangent frame ----------------------------------------------------

  describe "a tangent frame" do
    # The frame is (basis_u, basis_v, normal): unit vectors, each pair
    # perpendicular, and right-handed — `u × v` is the normal it rides on.
    defp assert_orthonormal_frame(frame, normal, tolerance \\ @tolerance) do
      u = TangentFrame.basis_u(frame)
      v = TangentFrame.basis_v(frame)

      assert_in_delta SpatialArithmetics.magnitude(u), 1.0, tolerance
      assert_in_delta SpatialArithmetics.magnitude(v), 1.0, tolerance
      assert_in_delta SpatialArithmetics.magnitude(normal), 1.0, tolerance

      assert_in_delta SpatialArithmetics.dot(u, v), 0.0, tolerance
      assert_in_delta SpatialArithmetics.dot(u, normal), 0.0, tolerance
      assert_in_delta SpatialArithmetics.dot(v, normal), 0.0, tolerance

      assert close?(SpatialArithmetics.cross(u, v), normal, tolerance)

      assert close?(
               SpatialArithmetics.cross(v, u),
               SpatialArithmetics.scale(normal, -1.0),
               tolerance
             )
    end

    # test_init_creates_orthonormal_frame
    test "a frame rides on its normal, square and right-handed" do
      for normal <- [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0], [1.0, 2.0, -3.0]] do
        unit_normal = SpatialArithmetics.normalize(normal)

        assert_orthonormal_frame(TangentFrame.new(unit_normal), unit_normal)
      end
    end

    # test_accumulated_transports_stay_orthonormal
    test "a thousand small steps across a surface leave the frame square" do
      # Monty walks a frame 1000 times over a surface that drifts a twentieth of
      # a unit a step, from a seeded generator so the walk is reproducible.
      :rand.seed(:exsss, {42, 42, 42})

      normal =
        [rand_normal(), rand_normal(), rand_normal()]
        |> SpatialArithmetics.normalize()

      {frame, normal} =
        Enum.reduce(1..1000, {TangentFrame.new(normal), normal}, fn _, {frame, normal} ->
          drifted =
            Enum.map(normal, fn value -> value + 0.05 * rand_normal() end)
            |> SpatialArithmetics.normalize()

          {TangentFrame.transport(frame, drifted), drifted}
        end)

      assert_orthonormal_frame(frame, normal)
    end

    # test_transport_to_same_normal_is_noop
    test "a frame carried to the normal it already rides on does not move" do
      for normal <- @directions do
        unit_normal = SpatialArithmetics.normalize(normal)
        frame = TangentFrame.new(unit_normal)

        carried = TangentFrame.transport(frame, unit_normal)

        assert close?(TangentFrame.basis_u(carried), TangentFrame.basis_u(frame))
        assert close?(TangentFrame.basis_v(carried), TangentFrame.basis_v(frame))
      end
    end

    # test_transport_preserves_orthonormality
    test "a frame carried to the opposite normal is still square" do
      # Monty names this one: the worst case, a half turn of the normal.
      from = SpatialArithmetics.normalize([1.0, 0.0, 0.0])
      to = SpatialArithmetics.normalize([-1.0, 0.0, 0.0])

      assert_orthonormal_frame(TangentFrame.transport(TangentFrame.new(from), to), to)
    end
  end

  # --- the angle between two vectors ----------------------------------------

  describe "the angle between two vectors" do
    # test_matches_normalized_dot_product
    test "the angle is the one the normalized dot product names" do
      # Monty's four examples: 45 degrees, parallel, anti-parallel, orthogonal.
      pairs = [
        {[2.0, 0.0, 0.0], [1.0, 1.0, 0.0]},
        {[2.0, 0.0, 0.0], [3.0, 0.0, 0.0]},
        {[2.0, 0.0, 0.0], [-3.0, 0.0, 0.0]},
        {[2.0, 0.0, 0.0], [0.0, -3.0, 0.0]}
      ]

      for {v1, v2} <- pairs do
        unit_1 = SpatialArithmetics.normalize(v1)
        unit_2 = SpatialArithmetics.normalize(v2)

        expected = :math.acos(unit_1 |> SpatialArithmetics.dot(unit_2) |> max(-1.0) |> min(1.0))
        actual = SpatialArithmetics.get_angle_between(v1, v2)

        assert actual >= 0.0 and actual <= :math.pi()
        assert_in_delta actual, expected, @tolerance
      end
    end

    # test_zero_vector_returns_zero
    test "an angle from the zero vector is zero, from either side" do
      zero = [0.0, 0.0, 0.0]

      for vector <- @directions do
        assert_in_delta SpatialArithmetics.get_angle_between(zero, vector), 0.0, @tolerance
        assert_in_delta SpatialArithmetics.get_angle_between(vector, zero), 0.0, @tolerance
      end
    end
  end
end
