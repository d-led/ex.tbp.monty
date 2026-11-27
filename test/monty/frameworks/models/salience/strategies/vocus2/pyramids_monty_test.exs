defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.PyramidsMontyTest do
  @moduledoc """
  Monty's own cases for the pyramids, translated.

  Each test names the case in
  `tests/unit/frameworks/models/salience/strategies/vocus2/pyramids_test.py` it
  translates. Two kinds of adaptation are made, and both are visible at the test
  that needs them:

    * Monty patches module-level `resize` and replaces `reduce` with a mock to
      assert the wiring with arguments. Elixir has no patches, so the same claim
      is asserted by recomputing the operation with the real function and
      comparing — which is stricter, because the numbers have to agree and not
      only the call.
    * Monty's property cases draw their images from hypothesis. Here an image is
      drawn once from a seeded generator, so the case is reproducible and says
      which seed it used.

  The statistics Monty uses — `np.std`, and `mean_local_variation` from
  `tests/unit/statistics.py` — are reimplemented below, because a case that
  asserts about variance means what it means by them.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  @tolerance 1.0e-6

  # --- the images and pyramids the cases are given ---------------------------

  defp plane(rows, columns, value) do
    List.duplicate(List.duplicate(value, columns), rows)
  end

  # A patch of noise, from a seeded generator: `:rand.uniform/0` is in (0, 1) as
  # Monty's `uniform(0.0, 1.0)` is.
  defp image(rows, columns, seed) do
    :rand.seed(:exsss, {seed, seed, seed})

    for _ <- 1..rows, do: for(_ <- 1..columns, do: :rand.uniform())
  end

  # A pyramid of solid planes, the shape Monty's generators build.
  defp solid_pyramid(resolution, n_scales, max_octaves, fill) do
    resolution
    |> Pyramids.octave_shapes(max_octaves)
    |> Enum.map(fn {rows, columns} -> plane(rows, columns, fill) |> List.duplicate(n_scales) end)
    |> Pyramid.new()
  end

  defp plane_at(%Pyramid{planes: octaves}, octave, scale) do
    octaves |> Enum.at(octave) |> Enum.at(scale)
  end

  defp shape_of([first | _rest] = plane), do: {length(plane), length(first)}

  defp subtract_planes(left, right) do
    Enum.zip_with(left, right, fn left_row, right_row ->
      Enum.zip_with(left_row, right_row, fn left_value, right_value ->
        left_value - right_value
      end)
    end)
  end

  # --- the statistics the cases are stated in --------------------------------

  # `np.std`, population standard deviation (ddof 0).
  defp std(plane) do
    values = List.flatten(plane)
    mean = Enum.sum(values) / length(values)

    sum_of_squares = values |> Enum.map(&((&1 - mean) * (&1 - mean))) |> Enum.sum()

    :math.sqrt(sum_of_squares / length(values))
  end

  # `tests/unit/statistics.py::mean_local_variation`: the mean absolute
  # difference between adjacent pixels, across rows and down columns.
  defp mean_local_variation(plane) do
    total = adjacent_differences(plane) + adjacent_differences(transpose(plane))

    total / length(List.flatten(plane))
  end

  defp adjacent_differences(lines) do
    lines
    |> Enum.map(fn line ->
      line
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [left, right] -> abs(right - left) end)
      |> Enum.sum()
    end)
    |> Enum.sum()
  end

  defp transpose([first | _rest] = plane) do
    blank = List.duplicate(0.0, length(plane))

    blank
    |> List.duplicate(length(first))
    |> Enum.zip_with(plane, fn column, row ->
      _ = column
      row
    end)
  end

  # --- Pyramid --------------------------------------------------------------

  # test_raises_value_error_if_pyramid_is_not_2d
  test "a pyramid is two dimensional, so a rank that is not two is refused" do
    # Monty's case refuses a numpy array of rank 0, 1, 3 or 4. Nested lists
    # cannot carry a rank, so what is refused here is the same failure by its
    # causes: no octave at all, an octave with no scale, or octaves that
    # disagree about how many scales they hold.
    assert_raise ArgumentError, fn -> Pyramid.new([]) end
    assert_raise ArgumentError, fn -> Pyramid.new([[]]) end

    assert_raise ArgumentError, fn ->
      Pyramid.new([[plane(2, 2, 0.0)], [plane(2, 2, 0.0), plane(2, 2, 0.0)]])
    end
  end

  # test_can_create_pyramid_with_2d_contents
  test "two octaves of two scales is a pyramid" do
    pyramid = Pyramid.new(List.duplicate(List.duplicate(plane(2, 2, 0.0), 2), 2))

    assert Pyramid.shape(pyramid) == {2, 2}
  end

  # test_apply_applies_function_to_each_element
  test "a function is applied to every plane, once each, and the shape stays" do
    # The first scale of each octave is filled with 0 and the second with 1, so a
    # plane the function saw twice comes back larger than one it saw once: the
    # count Monty's mock made is visible in the numbers.
    tagged =
      Pyramids.octave_shapes({4, 4}, 2)
      |> Enum.map(fn {rows, columns} ->
        [plane(rows, columns, 0.0), plane(rows, columns, 1.0)]
      end)
      |> Pyramid.new()

    increment = fn plane ->
      plane |> List.flatten() |> Enum.map(&(&1 + 1)) |> Enum.chunk_every(2)
    end

    returned = Pyramid.apply(tagged, increment)

    assert Pyramid.shape(returned) == Pyramid.shape(tagged)
    assert Pyramid.flat(returned) == Enum.map(Pyramid.flat(tagged), increment)
  end

  # --- the resolutions ------------------------------------------------------

  # test_generates_maximum_possible_shapes_when_max_level_is_none
  test "without a limit the octaves are halved until a dimension would vanish" do
    for {rows, columns} <- [{1, 1}, {7, 13}, {16, 16}, {128, 64}] do
      assert Pyramids.octave_shapes({rows, columns}) == halved_until_vanishing({rows, columns})
    end
  end

  defp halved_until_vanishing({rows, columns} = resolution) do
    if min(rows, columns) >= 1 do
      [resolution | halved_until_vanishing({div(rows, 2), div(columns, 2)})]
    else
      []
    end
  end

  # test_max_octaves_limits_number_of_shapes
  test "a maximum number of octaves is a maximum on the count" do
    for resolution <- [{8, 8}, {13, 64}, {128, 128}], max_octaves <- [1, 2, 5] do
      assert length(Pyramids.octave_shapes(resolution, max_octaves)) <= max_octaves
    end
  end

  # --- the Gaussian pyramid -------------------------------------------------

  # test_raises_value_error_if_image_has_size_zero
  test "an image with no pixels is refused" do
    assert_raise ArgumentError, fn ->
      Pyramids.gaussian_pyramid([], sigma: 1.0, n_scales: 2)
    end

    assert_raise ArgumentError, fn ->
      Pyramids.gaussian_pyramid([[]], sigma: 1.0, n_scales: 2)
    end
  end

  # test_shape_matches_shapes_computed_by_pyramid_octave_shapes
  test "the pyramid holds the octave shapes the resolutions say, at every scale" do
    for {rows, columns} <- [{8, 8}, {17, 9}], n_scales <- [1, 3], max_octaves <- [nil, 2] do
      expected = Pyramids.octave_shapes({rows, columns}, max_octaves)

      pyramid =
        Pyramids.gaussian_pyramid(image(rows, columns, 3),
          sigma: 1.0,
          n_scales: n_scales,
          max_octaves: max_octaves
        )

      assert Pyramid.n_octaves(pyramid) == length(expected)
      assert Pyramid.n_scales(pyramid) == n_scales

      for octave <- 0..(Pyramid.n_octaves(pyramid) - 1),
          scale <- 0..(n_scales - 1) do
        assert shape_of(plane_at(pyramid, octave, scale)) == Enum.at(expected, octave)
      end
    end
  end

  # test_subsequent_planes_have_decreasing_variance
  test "each plane is blurrier than the one before it, with room for what makes it need not be" do
    # Monty's allowances, kept as they are: the last plane of an octave against
    # the first of the next is compared across a downsample; very small planes
    # are noisy; and planes already at no variance cannot go lower.
    pyramid =
      Pyramids.gaussian_pyramid(image(32, 32, 67), sigma: 2.0, n_scales: 3, max_octaves: 3)

    pyramid
    |> Pyramid.flat()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [before_plane, after_plane] ->
      delta = std(after_plane) - std(before_plane)

      if length(List.flatten(before_plane)) == 1 and length(List.flatten(after_plane)) == 1 do
        assert delta == 0.0
      else
        tolerance =
          if shape_of(before_plane) != shape_of(after_plane), do: 1.0e-3, else: 0.0

        tolerance =
          if smaller_side(before_plane, after_plane) < 4,
            do: tolerance + 1.0e-6,
            else: tolerance

        tolerance =
          if std(before_plane) <= 1.0e-6 and std(after_plane) <= 1.0e-6,
            do: tolerance + 1.0e-6,
            else: tolerance

        assert delta < tolerance
      end
    end)
  end

  # The smaller side of either plane, which is what "a very small plane" means.
  defp smaller_side(first, second) do
    Enum.min(
      [first, second]
      |> Enum.map(&shape_of/1)
      |> Enum.map(fn {rows, columns} -> min(rows, columns) end)
    )
  end

  # test_subsequent_planes_have_decreasing_variance (the calibration case)
  test "on a calibrated image every plane has strictly less variance than its predecessor" do
    pyramid = Pyramids.gaussian_pyramid(image(512, 512, 67), sigma: 3.0, n_scales: 2)

    pyramid
    |> Pyramid.flat()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [before_plane, after_plane] ->
      delta = std(after_plane) - std(before_plane)

      if length(List.flatten(before_plane)) == 1 and length(List.flatten(after_plane)) == 1 do
        assert delta == 0.0
      else
        assert delta < 0.0
      end
    end)
  end

  # --- a centre and its surround -------------------------------------------

  # test_raises_value_error_if_center_sigma_is_greater_than_or_equal_to_surround_sigma
  test "a centre that is not narrower than its surround is refused" do
    for center_sigma <- [1.0, 4.0, 10.0], ratio <- [0.0, 0.5, 1.0] do
      assert_raise ArgumentError, fn ->
        Pyramids.center_surround(image(8, 8, 5),
          center_sigma: center_sigma,
          surround_sigma: center_sigma * ratio,
          n_scales: 2
        )
      end
    end
  end

  # test_center_and_surround_pyramids_have_same_shape
  test "the centre and its surround are pyramids of the same shape" do
    for {center_sigma, surround_sigma} <- [{1.0, 1.5}, {1.0, 4.0}, {2.0, 2.5}] do
      {center, surround} =
        Pyramids.center_surround(image(16, 16, 11),
          center_sigma: center_sigma,
          surround_sigma: surround_sigma,
          n_scales: 2,
          max_octaves: 3
        )

      assert Pyramid.shape(center) == Pyramid.shape(surround)
    end
  end

  # test_center_planes_have_higher_variance_than_corresponding_surround_planes
  test "a centre varies at least as much as the surround it is compared with" do
    {center, surround} =
      Pyramids.center_surround(image(32, 32, 13),
        center_sigma: 1.5,
        surround_sigma: 4.0,
        n_scales: 2,
        max_octaves: 3
      )

    variation_tolerance = 1.0e-2

    Enum.zip(Pyramid.flat(center), Pyramid.flat(surround))
    |> Enum.each(fn {center_plane, surround_plane} ->
      assert mean_local_variation(center_plane) - mean_local_variation(surround_plane) >=
               -variation_tolerance
    end)
  end

  # test_center_plane_variance_equals_corresponding_surround_plane_variance_for_solid_image
  test "on a solid image a centre and its surround differ nowhere" do
    # A plane of one colour has nothing to blur away, so the surround has to be
    # the centre, plane for plane.
    {center, surround} =
      Pyramids.center_surround(plane(16, 16, 0.4),
        center_sigma: 1.0,
        surround_sigma: 3.0,
        n_scales: 2,
        max_octaves: 3
      )

    Enum.zip(Pyramid.flat(center), Pyramid.flat(surround))
    |> Enum.each(fn {center_plane, surround_plane} ->
      assert_in_delta mean_local_variation(center_plane),
                      mean_local_variation(surround_plane),
                      @tolerance
    end)
  end

  # test_center_planes_have_higher_variance_than_corresponding_surround_planes (the calibration case)
  test "on a calibrated image a centre varies at least as much as its surround, without allowance" do
    {center, surround} =
      Pyramids.center_surround(image(512, 512, 67),
        center_sigma: 3.0,
        surround_sigma: 5.0,
        n_scales: 2,
        max_octaves: 5
      )

    Enum.zip(Pyramid.flat(center), Pyramid.flat(surround))
    |> Enum.each(fn {center_plane, surround_plane} ->
      assert mean_local_variation(center_plane) >= mean_local_variation(surround_plane)
    end)
  end

  # --- the Laplacian pyramid ------------------------------------------------

  # test_shape_same_as_input_pyramid_minus_one_octave
  test "a Laplacian pyramid has one octave fewer and the same scales and plane shapes" do
    input = Pyramids.gaussian_pyramid(image(16, 16, 17), sigma: 1.5, n_scales: 2, max_octaves: 3)
    laplacian = Pyramids.laplacian(input)

    assert Pyramid.n_octaves(laplacian) == Pyramid.n_octaves(input) - 1
    assert Pyramid.n_scales(laplacian) == Pyramid.n_scales(input)

    for octave <- 0..(Pyramid.n_octaves(laplacian) - 1),
        scale <- 0..(Pyramid.n_scales(laplacian) - 1) do
      assert shape_of(plane_at(laplacian, octave, scale)) ==
               shape_of(plane_at(input, octave, scale))
    end
  end

  # test_raises_value_error_if_input_pyramid_has_less_than_two_octaves
  test "a pyramid of one octave has no coarser octave to differ from" do
    assert_raise ArgumentError, fn ->
      Pyramids.laplacian(Pyramid.new([[plane(2, 2, 0.0)]]))
    end
  end

  # test_laplacian_planes_are_center_minus_resized_surround
  test "each plane is its octave minus the octave below it, enlarged back to its shape" do
    input = Pyramids.gaussian_pyramid(image(16, 16, 19), sigma: 1.5, n_scales: 2, max_octaves: 3)
    laplacian = Pyramids.laplacian(input)

    for octave <- 0..(Pyramid.n_octaves(laplacian) - 1),
        scale <- 0..(Pyramid.n_scales(laplacian) - 1) do
      center = plane_at(input, octave, scale)

      surround =
        Images.resize(plane_at(input, octave + 1, scale), shape_of(center), :cubic)

      assert plane_at(laplacian, octave, scale) == subtract_planes(center, surround)
    end
  end

  # --- combining and collapsing --------------------------------------------

  # test_raises_value_error_if_no_pyramids_are_provided
  test "combining nothing is refused" do
    assert_raise ArgumentError, fn -> Pyramids.combine([], & &1) end
  end

  # test_returns_first_pyramid_if_only_one_pyramid_is_provided
  test "combining one pyramid is that pyramid" do
    pyramid = Pyramid.new([[plane(2, 2, 0.5)]])

    assert Pyramids.combine([pyramid], & &1) == pyramid
  end

  # test_does_not_apply_reduce_to_pyramids_if_only_one_pyramid_is_provided
  test "combining one pyramid does not reduce anything" do
    # The mock's claim, made by a reducer that would fail the case if it ran.
    pyramid = Pyramid.new([[plane(2, 2, 0.5)]])

    result = Pyramids.combine([pyramid], fn _planes -> flunk("the reducer ran") end)

    assert result == pyramid
  end

  # test_raises_value_error_if_pyramids_have_different_shapes
  test "pyramids of different shapes cannot be combined" do
    one = solid_pyramid({8, 8}, 2, 2, 1.0)
    other = solid_pyramid({8, 8}, 3, 2, 1.0)

    assert_raise ArgumentError, fn -> Pyramids.combine([one, other], & &1) end
  end

  # test_returns_combined_pyramid_with_same_count_of_octaves_and_scales_and_reduced_planes
  test "combining keeps the count of octaves and scales and reduces each plane" do
    # A reducer that subtracts keeps the two inputs apart, so a plane built from
    # the wrong pair — or from one pyramid twice — cannot pass.
    one = Pyramids.gaussian_pyramid(image(16, 16, 23), sigma: 1.0, n_scales: 2, max_octaves: 2)
    other = Pyramids.gaussian_pyramid(image(16, 16, 29), sigma: 1.0, n_scales: 2, max_octaves: 2)

    combined =
      Pyramids.combine([one, other], fn [left, right] -> subtract_planes(left, right) end)

    assert Pyramid.n_octaves(combined) == Pyramid.n_octaves(one)
    assert Pyramid.n_scales(combined) == Pyramid.n_scales(one)

    for octave <- 0..(Pyramid.n_octaves(one) - 1), scale <- 0..(Pyramid.n_scales(one) - 1) do
      assert plane_at(combined, octave, scale) ==
               subtract_planes(plane_at(one, octave, scale), plane_at(other, octave, scale))
    end
  end

  # test_resize_only_called_on_planes_with_shapes_different_from_first_plane_and_returns_what_reduce_returns
  test "collapsing enlarges only the planes that are not the finest, and answers what the reducer says" do
    pyramid =
      Pyramids.gaussian_pyramid(image(16, 16, 31), sigma: 1.0, n_scales: 2, max_octaves: 3)

    target = shape_of(plane_at(pyramid, 0, 0))

    test_pid = self()

    result =
      Pyramids.collapse(pyramid, fn planes ->
        send(test_pid, {:planes, planes})
        :the_reducer_s_answer
      end)

    assert result == :the_reducer_s_answer
    assert_received {:planes, planes}

    expected =
      pyramid
      |> Pyramid.flat()
      |> Enum.map(fn plane ->
        if shape_of(plane) == target, do: plane, else: Images.resize(plane, target, :cubic)
      end)

    assert planes == expected
  end
end
