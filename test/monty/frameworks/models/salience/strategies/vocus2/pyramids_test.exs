defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.PyramidsTest do
  @moduledoc """
  What a pyramid is for, in terms small enough to check by eye.

  The numbers are held to Monty in `pyramids_parity_test.exs`; these say what
  the structure means: how many resolutions there are, that a coarse octave is
  the one above it resampled, that a surround is blurrier than its centre, and
  that a Laplacian keeps what a coarser octave could not hold.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  # A view with a bright blob in one corner: something for an attention model to
  # find, and structured enough that blurring changes it.
  defp image(rows \\ 8, columns \\ 8) do
    for row <- 0..(rows - 1) do
      for column <- 0..(columns - 1) do
        if row < div(rows, 2) and column < div(columns, 2), do: 200.0, else: 10.0
      end
    end
  end

  describe "the resolutions" do
    test "each octave is half the one before, stopping before a dimension vanishes" do
      assert Pyramids.octave_shapes({8, 8}) == [{8, 8}, {4, 4}, {2, 2}, {1, 1}]
      assert Pyramids.octave_shapes({5, 9}) == [{5, 9}, {2, 4}, {1, 2}]
    end

    test "a maximum number of octaves stops the pyramid early" do
      assert Pyramids.octave_shapes({8, 8}, 2) == [{8, 8}, {4, 4}]
    end
  end

  describe "a Gaussian pyramid" do
    test "holds the scales asked for at every resolution" do
      pyramid = Pyramids.gaussian_pyramid(image(), sigma: 1.0, n_scales: 3)

      assert Pyramid.shape(pyramid) == {4, 3}
      assert Pyramid.size(pyramid) == 12

      # Every plane of an octave is that octave's resolution: the scales are
      # blurs of one another, not resamplings.
      for {octave, {rows, columns}} <- Enum.zip(pyramid.planes, Pyramids.octave_shapes({8, 8})) do
        assert Enum.map(octave, fn plane -> {length(plane), length(hd(plane))} end) ==
                 List.duplicate({rows, columns}, 3)
      end
    end

    test "blurs more at each scale, so the difference between the corners shrinks" do
      [octave | _rest] = Pyramids.gaussian_pyramid(image(), sigma: 1.0, n_scales: 3).planes

      spread = fn plane ->
        plane |> List.flatten() |> Enum.max() |> Kernel.-(plane |> List.flatten() |> Enum.min())
      end

      assert octave |> Enum.map(spread) |> Enum.sort(:desc) == Enum.map(octave, spread)
    end
  end

  describe "a centre and its surround" do
    test "the surround is the centre blurred further, at the same resolutions" do
      {center, surround} =
        Pyramids.center_surround(image(), center_sigma: 1.0, surround_sigma: 2.5, n_scales: 2)

      assert Pyramid.shape(center) == Pyramid.shape(surround)

      # Blurring flattens: the centre keeps more contrast than its surround, at
      # every scale.
      contrast = fn plane ->
        plane |> List.flatten() |> Enum.max() |> Kernel.-(plane |> List.flatten() |> Enum.min())
      end

      centered = center |> Pyramid.flat() |> Enum.map(contrast)
      surrounded = surround |> Pyramid.flat() |> Enum.map(contrast)

      # Blurring never adds contrast, and at the finest scale — where there is
      # still something to blur — it visibly takes some away. At a one-pixel
      # scale there is nothing left to flatten, which is why this is not strict
      # everywhere.
      assert Enum.zip(centered, surrounded) |> Enum.all?(fn {c, s} -> c >= s end)
      assert hd(centered) > hd(surrounded)
    end

    test "a centre at least as wide as its surround is refused" do
      assert_raise ArgumentError, fn ->
        Pyramids.center_surround(image(), center_sigma: 2.0, surround_sigma: 2.0, n_scales: 2)
      end
    end
  end

  describe "a Laplacian pyramid" do
    test "has one fewer octave than the pyramid it came from" do
      pyramid = Pyramids.gaussian_pyramid(image(), sigma: 1.0, n_scales: 2)
      laplacian = Pyramids.laplacian(pyramid)

      assert Pyramid.n_octaves(laplacian) == Pyramid.n_octaves(pyramid) - 1
      assert Pyramid.n_scales(laplacian) == Pyramid.n_scales(pyramid)
    end

    test "a pyramid of one octave has no detail to differ from" do
      pyramid = Pyramids.gaussian_pyramid(image(), sigma: 1.0, n_scales: 2, max_octaves: 1)

      assert_raise ArgumentError, fn -> Pyramids.laplacian(pyramid) end
    end
  end

  describe "adding and subtracting pyramids" do
    test "planes add and subtract one for one" do
      one = Pyramid.new([[[[1.0, 2.0]], [[3.0, 4.0]]]])
      two = Pyramid.new([[[[10.0, 20.0]], [[30.0, 40.0]]]])

      assert Pyramid.flat(Pyramid.add(one, two)) == [[[11.0, 22.0]], [[33.0, 44.0]]]
      assert Pyramid.flat(Pyramid.subtract(two, one)) == [[[9.0, 18.0]], [[27.0, 36.0]]]
    end

    test "pyramids of different shapes cannot be added" do
      one = Pyramid.new([[[[1.0]]]])
      two = Pyramid.new([[[[1.0]]], [[[2.0]]]])

      assert_raise ArgumentError, fn -> Pyramid.add(one, two) end
    end
  end

  describe "combining and collapsing" do
    test "combining one pyramid is that pyramid" do
      pyramid = Pyramids.gaussian_pyramid(image(), sigma: 1.0, n_scales: 2)

      assert Pyramid.flat(Pyramids.combine_max([pyramid])) == Pyramid.flat(pyramid)
    end

    test "combining pyramids of different shapes is refused" do
      small = Pyramids.gaussian_pyramid(image(), sigma: 1.0, n_scales: 2)
      large = Pyramids.gaussian_pyramid(image(16, 16), sigma: 1.0, n_scales: 2)

      assert_raise ArgumentError, fn -> Pyramids.combine_max([small, large]) end
    end

    test "collapsing answers one image, the size of the finest scale" do
      pyramid = Pyramids.gaussian_pyramid(image(), sigma: 1.0, n_scales: 2)

      collapsed = Pyramids.collapse(pyramid, &Enum.max/1)

      assert {length(collapsed), collapsed |> hd() |> length()} == {8, 8}
    end
  end
end
