defmodule Monty.Frameworks.EnvironmentUtils.Transforms.ImageTransformsTest do
  @moduledoc """
  The transforms that work on the images themselves: noise, smoothing, blur.

  Each is specified against a number computed elsewhere rather than against
  itself. The smoothing's corners are a `sliding_window_view` reference of
  Monty's own definition, and the blur's kernel is what `cv2.GaussianBlur` (4.10)
  answers for the same sigma — the port's kernel matches it to `1.0e-7`, which is
  float32 precision, and that agreement is the claim being pinned here.
  """

  use ExUnit.Case, async: true

  alias Monty.Context

  alias Monty.Frameworks.EnvironmentUtils.Transforms.{
    AddNoiseToRawDepthImage,
    GaussianBlurRGB,
    GaussianSmoothing,
    NoDepthSensorPresent,
    TransformContext
  }

  @agent "agent_id_0"

  defp ctx(seed \\ 0, step \\ 0),
    do: %TransformContext{
      rng: Monty.Context.rng_for(%{Context.new(seed) | step: step}, "transform:0"),
      state: nil
    }

  defp observations(sensor_images), do: %{@agent => sensor_images}

  defp depth_observations(depth), do: observations(%{"patch" => %{"depth" => depth}})

  # A five by five ramp: the depth of pixel (i, j) is 5i + j + 1, so an
  # operation that mixes neighbours is visible in every number.
  defp ramp, do: Enum.map(0..4, fn row -> Enum.map(1..5, &(row * 5 + &1)) end)

  defp flat(value, rows \\ 5, columns \\ 5),
    do: List.duplicate(List.duplicate(value, columns), rows)

  describe "AddNoiseToRawDepthImage" do
    test "moves every depth by a draw from the step's stream" do
      transform = AddNoiseToRawDepthImage.new(agent_id: @agent, sigma: 0.01)

      %{@agent => %{"patch" => %{"depth" => depth}}} =
        AddNoiseToRawDepthImage.call(depth_observations(flat(1.0)), transform, ctx())

      refute depth == flat(1.0)
      assert depth |> List.flatten() |> Enum.all?(&(abs(&1 - 1.0) < 0.1))
    end

    test "draws the same noise twice for the same seed and step" do
      # The property that makes a noisy run comparable: the episode seed decides
      # the noise, not the wall clock (`docs/monty-bugs.md` §2.1).
      transform = AddNoiseToRawDepthImage.new(agent_id: @agent, sigma: 0.01)

      once = AddNoiseToRawDepthImage.call(depth_observations(flat(1.0)), transform, ctx(7, 3))
      twice = AddNoiseToRawDepthImage.call(depth_observations(flat(1.0)), transform, ctx(7, 3))

      assert once == twice
    end

    test "draws different noise at the next step" do
      transform = AddNoiseToRawDepthImage.new(agent_id: @agent, sigma: 0.01)

      refute AddNoiseToRawDepthImage.call(depth_observations(flat(1.0)), transform, ctx(7, 3)) ==
               AddNoiseToRawDepthImage.call(depth_observations(flat(1.0)), transform, ctx(7, 4))
    end

    test "leaves the depth alone when the noise is zero" do
      # A sigma of zero is a config that asked for noise and asked for none of
      # it: the values must come back exactly, not merely close.
      transform = AddNoiseToRawDepthImage.new(agent_id: @agent, sigma: 0.0)

      %{@agent => %{"patch" => %{"depth" => depth}}} =
        AddNoiseToRawDepthImage.call(depth_observations(flat(1.5)), transform, ctx())

      assert depth == flat(1.5)
    end

    test "is an error on a sensor with no depth, not a silent no-op" do
      transform = AddNoiseToRawDepthImage.new(agent_id: @agent, sigma: 0.01)

      assert_raise NoDepthSensorPresent, fn ->
        AddNoiseToRawDepthImage.call(
          observations(%{"patch" => %{}}),
          transform,
          ctx()
        )
      end
    end
  end

  describe "GaussianSmoothing" do
    test "smooths a ramp by the kernel Monty builds" do
      # `sigma: 2`, `kernel_width: 3`, edge padding, valid convolution. The
      # numbers are a `sliding_window_view` reference of Monty's definition; the
      # top-left pixel is the mean of the padded neighbourhood, and the centre of
      # the image is the ramp's own value because a plane is what a symmetric
      # kernel leaves alone.
      transform = GaussianSmoothing.new(agent_id: @agent, sigma: 2.0, kernel_width: 3)

      %{@agent => %{"patch" => %{"depth" => smoothed}}} =
        GaussianSmoothing.call(depth_observations(ramp()), transform, ctx())

      assert_in_delta smoothed |> hd() |> hd(), 2.915007, 1.0e-6
      assert_in_delta smoothed |> hd() |> Enum.at(2), 4.595839, 1.0e-6

      # The middle of a ramp is the ramp: a symmetric kernel moves nothing there.
      assert_in_delta smoothed |> Enum.at(2) |> Enum.at(2), 13.0, 1.0e-9
    end

    test "keeps the image's size, because the edges are repeated" do
      transform = GaussianSmoothing.new(agent_id: @agent, sigma: 2.0, kernel_width: 3)

      %{@agent => %{"patch" => %{"depth" => smoothed}}} =
        GaussianSmoothing.call(depth_observations(ramp()), transform, ctx())

      assert length(smoothed) == 5
      assert smoothed |> hd() |> length() == 5
    end

    test "leaves a flat image flat" do
      transform = GaussianSmoothing.new(agent_id: @agent, sigma: 2.0, kernel_width: 3)

      %{@agent => %{"patch" => %{"depth" => smoothed}}} =
        GaussianSmoothing.call(depth_observations(flat(0.3)), transform, ctx())

      assert smoothed |> List.flatten() |> Enum.all?(&(abs(&1 - 0.3) < 1.0e-12))
    end

    test "is an error on a sensor with no depth" do
      transform = GaussianSmoothing.new(agent_id: @agent)

      assert_raise NoDepthSensorPresent, fn ->
        GaussianSmoothing.call(observations(%{"patch" => %{}}), transform, ctx())
      end
    end
  end

  describe "GaussianBlurRGB" do
    test "spreads a pixel by the kernel OpenCV uses for the same sigma" do
      # OpenCV is not a dependency here, so these are numbers it produced for
      # this exact input — a 3x3 black image with one white pixel, sigma 1, a
      # 5-pixel kernel — and the port answers them to float32 precision.
      image =
        for row <- 0..2 do
          for column <- 0..2 do
            if {row, column} == {1, 1}, do: [1.0, 1.0, 1.0, 1.0], else: [0.0, 0.0, 0.0, 1.0]
          end
        end

      transform = GaussianBlurRGB.new(agent_id: @agent, sigma: 1.0, kernel_size: 5)

      %{@agent => %{"patch" => %{"rgba" => blurred}}} =
        GaussianBlurRGB.call(observations(%{"patch" => %{"rgba" => image}}), transform, ctx())

      expected = [
        [0.238537, 0.249866, 0.238537],
        [0.249866, 0.261732, 0.249866],
        [0.238537, 0.249866, 0.238537]
      ]

      assert Enum.map(blurred, &length/1) == [3, 3, 3]

      for {row, row_expected} <- Enum.zip(blurred, expected),
          {{red, _green, _blue, alpha}, value} <- Enum.zip(row, row_expected) do
        assert_in_delta red, value, 1.0e-6

        # The alpha channel is the image's own, untouched by the blur.
        assert alpha == 1.0
      end
    end

    test "blurs only the sensors a config names" do
      transform =
        GaussianBlurRGB.new(agent_id: @agent, sigma: 1.0, kernel_size: 3, sensor_ids: ["patch"])

      blurred =
        GaussianBlurRGB.call(
          observations(%{
            "patch" => %{"rgba" => [[[1.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0]]]},
            "view_finder" => %{"rgba" => [[[0.0, 1.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0]]]}
          }),
          transform,
          ctx()
        )

      # The view finder's pixels are the ones it was given; the patch's red bled
      # into its black neighbour.
      assert %{
               @agent => %{
                 "patch" => %{"rgba" => [[[red, _, _, 1.0], [neighbour, _, _, 1.0]]]},
                 "view_finder" => %{"rgba" => view_finder}
               }
             } = blurred

      assert view_finder == [[[0.0, 1.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0]]]
      assert red < 1.0
      assert neighbour > 0.0
    end

    test "refuses a kernel size it cannot mean" do
      # Monty validates these in its constructor and so does the port: an even
      # kernel has no centre pixel, and a sigma of zero with an auto kernel has
      # no width at all.
      assert_raise ArgumentError, ~r/kernel_size must be odd/, fn ->
        GaussianBlurRGB.new(agent_id: @agent, kernel_size: 4)
      end

      assert_raise ArgumentError, ~r/non-negative/, fn ->
        GaussianBlurRGB.new(agent_id: @agent, kernel_size: -1)
      end

      assert_raise ArgumentError, ~r/sigma must be positive/, fn ->
        GaussianBlurRGB.new(agent_id: @agent, sigma: 0.0)
      end

      assert_raise ArgumentError, ~r/sensor_ids must not be empty/, fn ->
        GaussianBlurRGB.new(agent_id: @agent, sensor_ids: [])
      end
    end

    test "derives the kernel size from sigma the way OpenCV does" do
      # `cv2.GaussianBlur(..., (0, 0), sigma)` on a float image: 8*sigma + 1,
      # rounded and forced odd — 17 pixels at sigma 2, not the 13 Monty's comment
      # says.
      assert length(GaussianBlurRGB.new(agent_id: @agent, sigma: 2.0).kernel) == 17
      assert length(GaussianBlurRGB.new(agent_id: @agent, sigma: 1.0).kernel) == 9
      assert length(GaussianBlurRGB.new(agent_id: @agent, sigma: 1.5).kernel) == 13
    end

    test "refuses the case it cannot reproduce, rather than blurring by a guessed rule" do
      # OpenCV derives a sigma from an explicit kernel size using a fixed-point
      # table; the port cannot reproduce it beyond the sizes it could measure, so
      # a config that asks for it is told rather than silently given other
      # numbers. Every config Monty ships that uses this transform gives a sigma.
      assert_raise ArgumentError, ~r/has not reproduced/, fn ->
        GaussianBlurRGB.new(agent_id: @agent, sigma: 0.0, kernel_size: 3)
      end
    end
  end
end
