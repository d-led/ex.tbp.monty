defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.ImagesTest do
  @moduledoc """
  What the colour spaces and the image operations mean.

  The numbers themselves are held to OpenCV in `images_parity_test.exs`; these
  say what each operation is *for*, with images small enough to check by hand.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images

  # One pixel through a converter, as the three numbers it answers with.
  defp convert(pixel, converter) do
    [[converted]] = converter.([[pixel]])
    Enum.map(converted, &Float.round(&1, 4))
  end

  describe "the opponent colour spaces" do
    test "a neutral grey sits in the middle of both colour axes of the shifted space" do
      # The shifted spelling puts a signed axis inside [0, 1], so grey — which
      # has nothing to report — lands at a half.
      assert convert([128, 128, 128], &Images.rgb_to_opponent/1) == [0.502, 0.5, 0.5]
    end

    test "the unshifted spelling leaves a neutral grey at zero" do
      # Klein and Frintrop's spelling keeps the sign, so grey is the origin of
      # both colour axes and the sign of an axis means something.
      assert convert([128, 128, 128], &Images.rgb_to_opponent_codi/1) == [0.502, 0.0, 0.0]
    end

    test "red and green are opposite ends of the first colour axis" do
      red = convert([255, 0, 0], &Images.rgb_to_opponent/1)
      green = convert([0, 255, 0], &Images.rgb_to_opponent/1)
      blue = convert([0, 0, 255], &Images.rgb_to_opponent/1)

      # Brightness is the mean of the three channels, so every pure primary has
      # the same lightness; only the colour axes tell them apart.
      assert Enum.map([red, green, blue], &hd/1) == [0.3333, 0.3333, 0.3333]
      assert Enum.at(red, 1) == 1.0
      assert Enum.at(green, 1) == 0.0

      # Blue is the end of the second axis, which is blue against red and green
      # together: red and green are equally low on it.
      assert Enum.at(blue, 2) == 1.0
      assert Enum.at(red, 2) == Enum.at(green, 2)
    end
  end

  describe "Lab" do
    test "black and white are the ends of the lightness channel and both are neutral" do
      [black_lightness, black_a, black_b] = convert([0, 0, 0], &Images.rgb_to_lab/1)
      [white_lightness, white_a, white_b] = convert([255, 255, 255], &Images.rgb_to_lab/1)

      assert black_lightness == 0.0
      assert white_lightness == 1.0

      # 128 of 255 is where OpenCV puts no colour at all.
      assert [black_a, black_b] == [0.502, 0.502]
      assert [white_a, white_b] == [0.502, 0.502]
    end

    test "lightness is not the mean of the channels, as it is in RGB" do
      # Green reads far brighter than blue to the eye, which is the whole reason
      # the attention model does not work in RGB.
      [green_lightness | _] = convert([0, 255, 0], &Images.rgb_to_lab/1)
      [blue_lightness | _] = convert([0, 0, 255], &Images.rgb_to_lab/1)

      assert green_lightness > blue_lightness
    end
  end

  describe "blurring" do
    test "spreads a bright pixel into its neighbours and leaves a flat image flat" do
      plane = [
        [10.0, 10.0, 10.0],
        [10.0, 200.0, 10.0],
        [10.0, 10.0, 10.0]
      ]

      blurred = Images.gaussian_blur(plane, 1.0)

      # The kernel sums to one, so nothing is created — only spread.
      assert Enum.at(Enum.at(blurred, 1), 1) < 200.0
      assert Enum.at(Enum.at(blurred, 0), 0) > 10.0
      assert blurred |> List.flatten() |> Enum.all?(&(&1 > 10.0 and &1 < 200.0))

      # A flat image is a fixed point: every window already averages to itself.
      flat = List.duplicate(List.duplicate(7.0, 4), 4)
      assert Images.gaussian_blur(flat, 1.5) == flat
    end

    test "the border repeats the edge pixel rather than reflecting it" do
      # With reflection the far end of the row would be pulled towards the
      # middle's neighbours; with replication it stays near the edge's own value.
      row = [[0.0, 0.0, 0.0, 9.0, 9.0, 9.0]]

      [blurred] = Images.gaussian_blur(row, 1.0)

      assert hd(blurred) < 1.0
      assert List.last(blurred) > 8.0
    end
  end

  describe "resizing" do
    test "shrinking by area averages what each destination pixel covers" do
      # Four quadrants, each becoming exactly one destination pixel.
      plane = [
        [0.0, 0.0, 1.0, 1.0],
        [0.0, 0.0, 1.0, 1.0],
        [2.0, 2.0, 3.0, 3.0],
        [2.0, 2.0, 3.0, 3.0]
      ]

      assert Images.resize(plane, {2, 2}, :area) == [[0.0, 1.0], [2.0, 3.0]]
    end

    test "enlarging by cubic keeps a flat image flat" do
      flat = List.duplicate(List.duplicate(5.0, 3), 3)

      enlarged = Images.resize(flat, {6, 6}, :cubic)

      assert enlarged |> List.flatten() |> Enum.all?(&(abs(&1 - 5.0) < 1.0e-12))
    end

    test "enlarging by cubic passes through the ends and rings at a step" do
      # Two flat runs either side of a step. An interpolating cubic passes
      # through values it is given and, between them, overshoots — ringing —
      # which is the price of being smooth. It is why a pyramid shrinks by area
      # and enlarges by cubic.
      ramp = [[0.0, 0.0, 0.0, 10.0, 10.0, 10.0]]

      [interpolated] = Images.resize(ramp, {1, 11}, :cubic)

      assert hd(interpolated) == 0.0
      assert List.last(interpolated) == 10.0
      assert Enum.any?(interpolated, &(&1 > 0.0 and &1 < 10.0))
      assert Enum.min(interpolated) < 0.0
      assert Enum.max(interpolated) > 10.0
    end

    test "resizing to the shape it already has changes nothing" do
      plane = [[1.0, 2.0], [3.0, 4.0]]

      assert Images.resize(plane, {2, 2}, :area) == plane
      assert Images.resize(plane, {2, 2}, :cubic) == plane
    end
  end
end
