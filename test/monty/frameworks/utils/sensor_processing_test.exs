defmodule Monty.Frameworks.Utils.SensorProcessingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Frameworks.Utils.SensorProcessing
  alias Monty.Geometry.Rotation
  alias Monty.Geometry.SurfacePoseVectors
  alias Monty.Math

  defmodule Patch do
    @moduledoc false

    # A patch in the shape the depth-to-points transform leaves it: one row per
    # pixel, `[x, y, z, on_surface]`, row by row.

    def grid(width, spread, height \\ fn _x, _y -> 0.0 end) do
      for row <- 0..(width - 1), column <- 0..(width - 1) do
        x = (column - (width - 1) / 2) / (width - 1) * 2 * spread
        y = ((width - 1) / 2 - row) / (width - 1) * 2 * spread
        [x, y, height.(x, y), 1.0]
      end
    end

    def center_id(patch) do
      half = div(width(patch), 2)
      half * width(patch) + half
    end

    def width(patch), do: patch |> length() |> :math.sqrt() |> round()

    # The top half is off the object, and somewhere else entirely — which is what
    # an object behind the one the camera is pointed at looks like.
    def with_top_off_object(patch) do
      half = div(length(patch), 2)

      patch
      |> Enum.with_index()
      |> Enum.map(fn {[x, y, z, mask], index} ->
        if index < half, do: [x, y, z + 5.0, 0.0], else: [x, y, z, mask]
      end)
    end

    def with_middle_off_object(patch) do
      middle = center_id(patch)

      patch
      |> Enum.with_index()
      |> Enum.map(fn {[x, y, z, _mask], index} ->
        [x, y, z, if(index == middle, do: 0.0, else: 1.0)]
      end)
    end
  end

  describe "the signed logarithm" do
    test "scales a value without losing which way it points" do
      assert_in_delta SensorProcessing.log_sign(9.0), :math.log(10.0), 1.0e-12
      assert_in_delta SensorProcessing.log_sign(-9.0), -:math.log(10.0), 1.0e-12
    end

    test "keeps zero at zero, where a plain logarithm would run off" do
      assert SensorProcessing.log_sign(0.0) == 0.0
    end

    test "and applies to a curvature pair as Monty's sensor applies it" do
      assert_in_delta hd(SensorProcessing.log_sign([-20.0, 20.0])), -:math.log(21.0), 1.0e-12

      assert_in_delta List.last(SensorProcessing.log_sign([-20.0, 20.0])),
                      :math.log(21.0),
                      1.0e-12
    end
  end

  describe "a patch's surface normal" do
    test "is the normal of the plane its points lie in" do
      assert {normal, true} = normal(plane())

      assert_in_delta abs(dot(normal, [0.0, 0.0, 1.0])), 1.0, 1.0e-6
    end

    test "and faces the camera that saw it" do
      # Monty aligns the normal with the viewing direction, so the answer is not
      # the plane's two-sided normal but the side the sensor is on.
      {from_above, true} = normal(plane(), [0.0, 0.0, 1.0])
      {from_below, true} = normal(plane(), [0.0, 0.0, -1.0])

      assert_in_delta dot(from_above, [0.0, 0.0, 1.0]), 1.0, 1.0e-6
      assert_in_delta dot(from_below, [0.0, 0.0, -1.0]), 1.0, 1.0e-6
    end

    test "and ignores the pixels that are not on the object" do
      # The pixels off the object are five metres away: a normal fitted across
      # them is a normal of nothing.
      assert {normal, true} = normal(Patch.with_top_off_object(plane()))

      assert_in_delta abs(dot(normal, [0.0, 0.0, 1.0])), 1.0, 1.0e-6
    end

    test "and a middle pixel off the object has no normal at all" do
      assert {[0.0, 0.0, 1.0], false} = normal(Patch.with_middle_off_object(plane()))
    end
  end

  describe "a patch's principal curvatures" do
    test "are the sphere's own, both the same, and negative as convex ones are" do
      # A five-centimetre sphere: -1/r is -20 in Monty's units, and a sphere bends
      # the same amount in every direction. The fit sees a finite patch, so the
      # quartic terms move it a little off the exact figure.
      assert {first, second, direction_1, direction_2, true} = curvatures(sphere())

      assert_in_delta first, -20.0, 0.4
      assert_in_delta second, -20.0, 0.4
      assert length(direction_1) == 3
      assert length(direction_2) == 3
    end

    test "and a saddle's are opposite, largest first" do
      # z = (x^2 - y^2) / 2R bends up along x and down along y, with curvatures
      # +1/R and -1/R.
      radius = 0.1
      saddle = Patch.grid(41, 0.01, fn x, y -> (x * x - y * y) / (2.0 * radius) end)

      assert {first, second, _direction_1, _direction_2, true} = curvatures(saddle)

      assert_in_delta first, 10.0, 0.2
      assert_in_delta second, -10.0, 0.2
    end

    test "and a flat patch has none" do
      assert {first, second, _direction_1, _direction_2, true} = curvatures(plane())

      assert_in_delta first, 0.0, 1.0e-6
      assert_in_delta second, 0.0, 1.0e-6
    end

    test "and the directions are square to the normal and to each other" do
      {normal, true} = normal(sphere())
      assert {_first, _second, direction_1, direction_2, true} = curvatures(sphere())

      assert_in_delta dot(direction_1, normal), 0.0, 1.0e-6
      assert_in_delta dot(direction_2, normal), 0.0, 1.0e-6
      assert_in_delta dot(direction_1, direction_2), 0.0, 1.0e-6
    end

    test "and a middle pixel off the object has none" do
      assert {0.0, 0.0, [0.0, 0.0, 0.0], [0.0, 0.0, 0.0], false} =
               SensorProcessing.principal_curvatures(
                 Patch.with_middle_off_object(plane()),
                 Patch.center_id(plane()),
                 [0.0, 0.0, 1.0]
               )
    end
  end

  describe "the neighbourhood a fit uses" do
    test "is every pixel within a fraction of the patch's width, and its own middle" do
      # A three-by-three patch whose neighbourhood is the whole of it: nine
      # points, relative to the middle one.
      patch = Patch.grid(3, 0.01)

      neighbors = SensorProcessing.center_neighbors(patch, Patch.center_id(patch), 1.0)

      assert length(neighbors) == 9
      assert Enum.all?(neighbors, fn point -> length(point) == 3 end)

      assert [0.0, 0.0, 0.0] in Enum.map(neighbors, fn [x, y, z] ->
               [Float.round(x, 12), Float.round(y, 12), Float.round(z, 12)]
             end)
    end

    test "and only the pixels that are on the object" do
      patch = Patch.with_top_off_object(plane())
      neighbors = SensorProcessing.center_neighbors(patch, Patch.center_id(patch), 3.2)

      assert neighbors != []
      assert length(neighbors) < length(patch)
    end
  end

  describe "the weights a fit uses" do
    test "are a Gaussian around the middle that sums to one" do
      weights =
        SensorProcessing.weight_matrix(41 * 41, Patch.center_id(plane()),
          neighbor_patch_frac: 2.13
        )

      assert_in_delta Enum.sum(weights), 1.0, 1.0e-12
      assert Enum.at(weights, Patch.center_id(plane())) > hd(weights)
      assert Enum.all?(weights, &(&1 > 0.0))
    end
  end

  # -- fixtures --------------------------------------------------------------

  defp plane, do: Patch.grid(41, 0.01)

  defp sphere do
    radius = 0.05
    Patch.grid(41, 0.01, fn x, y -> :math.sqrt(radius * radius - x * x - y * y) - radius end)
  end

  defp normal(patch, view_direction \\ [0.0, 0.0, 1.0]) do
    SensorProcessing.surface_normal_total_least_squares(
      patch,
      Patch.center_id(patch),
      view_direction
    )
  end

  defp curvatures(patch) do
    {normal, true} = normal(patch)
    SensorProcessing.principal_curvatures(patch, Patch.center_id(patch), normal)
  end

  defp dot(left, right), do: Enum.zip_with([left, right], fn [a, b] -> a * b end) |> Enum.sum()

  describe "a pixel as hue, saturation and value" do
    test "puts the three primaries a third of the wheel apart" do
      assert SensorProcessing.rgb2hsv([1.0, 0.0, 0.0]) == [0.0, 1.0, 1.0]

      assert [green_hue, 1.0, 1.0] = SensorProcessing.rgb2hsv([0.0, 1.0, 0.0])
      assert_in_delta green_hue, 1.0 / 3.0, 1.0e-12

      assert [blue_hue, 1.0, 1.0] = SensorProcessing.rgb2hsv([0.0, 0.0, 1.0])
      assert_in_delta blue_hue, 2.0 / 3.0, 1.0e-12
    end

    test "wraps hue round the wheel instead of going negative" do
      # A red-dominant pixel just past blue: the wheel comes back to red.
      assert [hue, _saturation, _value] = SensorProcessing.rgb2hsv([1.0, 0.0, 0.5])
      assert_in_delta hue, 1.0 - 30.0 / 360.0, 1.0e-12
    end

    test "has no hue and no saturation for a grey pixel" do
      assert [hue, saturation, value] = SensorProcessing.rgb2hsv([0.5, 0.5, 0.5])

      assert {hue, saturation, value} == {0.0, 0.0, 0.5}
    end

    test "and nothing at all for black" do
      assert SensorProcessing.rgb2hsv([0.0, 0.0, 0.0]) == [0.0, 0.0, 0.0]
    end

    # A camera hands over byte samples, and skimage scales them before it does
    # anything else (`img_as_float`): a `uint8` pixel means `n / 255`. All four
    # answers below are `skimage.color.rgb2hsv`'s own, from numpy 1.23.5 in
    # Monty's environment — a run whose value channel stayed on 0..255 scored
    # every hypothesis differently from Monty's, which is how this was found.
    test "reads a byte pixel on the 0..1 scale, as skimage does" do
      assert SensorProcessing.rgb2hsv([143, 47, 50]) == [
               0.9947916666666666,
               0.6713286713286714,
               0.5607843137254902
             ]

      assert SensorProcessing.rgb2hsv([255, 0, 0]) == [0.0, 1.0, 1.0]

      assert SensorProcessing.rgb2hsv([0, 128, 64]) == [
               0.4166666666666667,
               1.0,
               0.5019607843137255
             ]
    end

    test "keeps a grey byte pixel's value, which is not zero" do
      assert [hue, saturation, value] = SensorProcessing.rgb2hsv([10, 10, 10])

      assert {hue, saturation} == {0.0, 0.0}
      assert_in_delta value, 10.0 / 255.0, 1.0e-12
    end
  end

  describe "point_pair_features/4" do
    # A displacement module compares a step's displacement with a stored edge by
    # these four numbers: how far apart the points are, and the three angles the
    # line between them makes with the two surface normals.
    test "measures the line between two points and its angles to both normals" do
      features =
        SensorProcessing.point_pair_features(
          [0.0, 0.0, 0.0],
          [1.0, 0.0, 0.0],
          [1.0, 0.0, 0.0],
          [0.0, 1.0, 0.0]
        )

      assert [length, from_first, from_second, between_normals] = features
      assert_in_delta length, 1.0, 1.0e-12
      assert_in_delta from_first, 0.0, 1.0e-12
      assert_in_delta from_second, :math.pi() / 2, 1.0e-12
      assert_in_delta between_normals, :math.pi() / 2, 1.0e-12
    end

    # The line is taken from the first point to the second, so the two points
    # are not interchangeable: swapping them reverses the line and turns the
    # angles measured from it round.
    test "takes the line from the first point to the second" do
      [_, forward_first, _, _] =
        SensorProcessing.point_pair_features(
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 1.0],
          [0.0, 0.0, 1.0],
          [0.0, 0.0, 1.0]
        )

      [_, backward_first, _, _] =
        SensorProcessing.point_pair_features(
          [0.0, 0.0, 1.0],
          [0.0, 0.0, 0.0],
          [0.0, 0.0, 1.0],
          [0.0, 0.0, 1.0]
        )

      assert_in_delta forward_first, 0.0, 1.0e-12
      assert_in_delta backward_first, :math.pi(), 1.0e-12
    end
  end

  # -- how far along a curved surface a step really went ---------------------
  #
  # The cases below translate Monty's `ComputeArcFromTangentProjectionTest` and
  # `DirectionalCurvatureTest` in
  # `tests/unit/frameworks/utils/sensor_processing_test.py`, one for one.

  describe "a tangent-plane projection, as an arc" do
    # test_known_correction
    test "corrects a chord on a unit circle to its arc" do
      assert_in_delta SensorProcessing.arc_from_projection(0.5, 1.0), :math.pi() / 6, 1.0e-12
    end

    # test_out_of_bounds_params_edge_case
    test "leaves the projection alone when the step reaches the far side of the circle" do
      assert SensorProcessing.arc_from_projection(1.0, 1.0) == 1.0
    end

    # test_corrected_length_geq_projection
    property "never reports less than the projection it was given" do
      check all(
              projection <- projection_generator(),
              curvature <- curvature_generator()
            ) do
        arc = SensorProcessing.arc_from_projection(projection, curvature)
        assert abs(arc) >= abs(projection)
      end
    end

    # test_sign_preservation
    property "keeps the sign of the projection, and a zero projection is zero" do
      check all(
              projection <- projection_generator(),
              curvature <- curvature_generator()
            ) do
        arc = SensorProcessing.arc_from_projection(projection, curvature)

        cond do
          projection > 0.0 -> assert arc > 0.0
          projection < 0.0 -> assert arc < 0.0
          true -> assert arc == 0.0
        end
      end

      assert SensorProcessing.arc_from_projection(0.0, 2.0) == 0.0
    end

    # test_negating_projection_negates_result
    property "is an odd function of the projection" do
      check all(
              projection <- projection_generator(),
              curvature <- curvature_generator()
            ) do
        assert SensorProcessing.arc_from_projection(-projection, curvature) ==
                 -1.0 * SensorProcessing.arc_from_projection(projection, curvature)
      end
    end

    # test_curvature_sign_does_not_affect_result
    property "curves the same way whether the surface is convex or concave" do
      check all(
              projection <- projection_generator(),
              curvature <- curvature_generator()
            ) do
        assert SensorProcessing.arc_from_projection(projection, curvature) ==
                 SensorProcessing.arc_from_projection(projection, -curvature)
      end
    end

    # test_flat_bypass_returns_projection
    property "leaves a projection on a nearly flat surface untouched" do
      check all({projection, curvature} <- flat_regime_generator()) do
        assert SensorProcessing.arc_from_projection(projection, curvature) == projection
      end
    end

    # test_out_of_bounds_returns_projection
    property "leaves a projection longer than the radius of curvature untouched" do
      check all({projection, curvature} <- out_of_bounds_regime_generator()) do
        assert SensorProcessing.arc_from_projection(projection, curvature) == projection
      end
    end
  end

  describe "a surface's curvature in one direction" do
    # test_zero_direction_returns_zero
    property "is nothing in a direction of zero length" do
      check all(
              {pc1, pc2} <- orthonormal_pair_generator(),
              {k1, k2} <- curvature_values_generator()
            ) do
        assert SensorProcessing.directional_curvature([0.0, 0.0, 0.0], k1, k2, pc1, pc2) == 0.0
      end
    end

    # test_euler_formula
    property "follows Euler's formula between the two principal directions" do
      check all(
              angle <- StreamData.float(min: 0.0, max: 2 * :math.pi()),
              {k1, k2} <- curvature_values_generator(),
              {pc1, pc2} <- orthonormal_pair_generator()
            ) do
        direction = combine(pc1, :math.cos(angle), pc2, :math.sin(angle))

        expected = k1 * :math.cos(angle) ** 2 + k2 * :math.sin(angle) ** 2

        tolerance =
          Enum.max([
            Math.default_tolerance() * abs(k1),
            Math.default_tolerance() * abs(k2),
            Math.default_tolerance()
          ])

        assert_in_delta SensorProcessing.directional_curvature(direction, k1, k2, pc1, pc2),
                        expected,
                        tolerance
      end
    end

    # test_out_of_plane_movement_raises
    property "refuses a movement that is not in the plane of the principal directions" do
      check all({pc1, pc2} <- orthonormal_pair_generator()) do
        out_of_plane = cross(pc1, pc2)

        assert_raise ArgumentError, ~r/must lie in the plane/, fn ->
          SensorProcessing.directional_curvature(out_of_plane, 1.0, 2.0, pc1, pc2)
        end
      end
    end

    # test_pcs_not_unit_vectors_raises
    property "refuses principal directions that are not unit vectors" do
      check all({pc1, pc2} <- orthonormal_pair_generator()) do
        assert_raise ArgumentError, ~r/must be unit vectors/, fn ->
          SensorProcessing.directional_curvature(pc1, 1.0, 2.0, times(pc1, 2.0), pc2)
        end

        assert_raise ArgumentError, ~r/must be unit vectors/, fn ->
          SensorProcessing.directional_curvature(pc2, 1.0, 2.0, pc1, times(pc2, 2.0))
        end
      end
    end
  end

  describe "a 2-D movement on a curved surface" do
    test "is lengthened along each direction by that direction's curvature" do
      # Curvature 1 along `x` and 0 along `y`: a decimetre along x becomes
      # asin(0.5)/1, and the same decimetre along y is on a flat surface, so it
      # stays a decimetre.
      curvatures = SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])

      assert {arc_u, arc_v} =
               SensorProcessing.arc_length_corrected_displacement(
                 0.5,
                 0.5,
                 [1.0, 0.0, 0.0],
                 [0.0, 1.0, 0.0],
                 [1.0, 0.0],
                 curvatures
               )

      assert_in_delta arc_u, :math.pi() / 6, 1.0e-12
      assert_in_delta arc_v, 0.5, 1.0e-12
    end
  end

  # -- the generators the cases above draw from -----------------------------

  @max_projection 0.05
  @max_curvature 1.0e3

  defp projection_generator do
    StreamData.one_of([
      StreamData.float(min: -@max_projection, max: @max_projection),
      StreamData.constant(0.0)
    ])
  end

  defp curvature_generator do
    StreamData.one_of([
      StreamData.float(min: -@max_curvature, max: @max_curvature),
      StreamData.constant(0.0)
    ])
  end

  defp curvature_values_generator do
    gen all(
          k1 <- StreamData.float(min: -@max_curvature, max: @max_curvature),
          k2 <- StreamData.float(min: -@max_curvature, max: @max_curvature)
        ) do
      # Monty's `assume(k1 >= k2)`: the first principal curvature is the larger.
      {max(k1, k2), min(k1, k2)}
    end
  end

  # Two directions of one orthonormal frame: the rows of a random rotation, so
  # they are unit and perpendicular by construction rather than by rounding.
  defp orthonormal_pair_generator do
    gen all(
          x <- StreamData.float(min: -1.0, max: 1.0),
          y <- StreamData.float(min: -1.0, max: 1.0),
          z <- StreamData.float(min: -1.0, max: 1.0),
          angle <- StreamData.float(min: -:math.pi(), max: :math.pi()),
          axis <- StreamData.constant(normalise([x, y, z]))
        ) do
      {:ok, rotation} = Rotation.from_axis_angle(axis, angle)
      [_normal, first, second] = Rotation.to_matrix(rotation)
      {first, second}
    end
  end

  # A tangent-plane movement whose product with its curvature is below Monty's
  # flat threshold, and one whose product is past the radius of curvature.
  defp regime_generator(min_product, max_product) do
    gen all(
          product <- StreamData.float(min: min_product, max: max_product),
          curvature <- StreamData.float(min: 0.01, max: @max_curvature),
          sign <- StreamData.integer(0..1)
        ) do
      # A step never reaches further than `@max_projection`, so a product this
      # large needs a curvature sharp enough to keep the projection inside it.
      curvature = max(curvature, product / @max_projection)
      projection = product / curvature
      if sign == 0, do: {projection, curvature}, else: {-projection, curvature}
    end
  end

  defp flat_regime_generator,
    do: regime_generator(0.0, SensorProcessing.flat_threshold() - 1.0e-6)

  defp out_of_bounds_regime_generator, do: regime_generator(1.0 + 1.0e-6, 2.0)

  defp normalise([x, y, z]) do
    length = :math.sqrt(x * x + y * y + z * z)
    if length < 0.1, do: [1.0, 0.0, 0.0], else: [x / length, y / length, z / length]
  end

  defp combine(first, first_scale, second, second_scale) do
    first |> Enum.zip(second) |> Enum.map(fn {a, b} -> a * first_scale + b * second_scale end)
  end

  defp cross([a1, a2, a3], [b1, b2, b3]) do
    [a2 * b3 - a3 * b2, a3 * b1 - a1 * b3, a1 * b2 - a2 * b1]
  end

  defp times(vector, factor), do: Enum.map(vector, &(&1 * factor))
end
