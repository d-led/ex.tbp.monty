defmodule Monty.Frameworks.Utils.SensorProcessingTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Utils.SensorProcessing

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
end
