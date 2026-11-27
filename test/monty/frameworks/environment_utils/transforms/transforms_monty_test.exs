defmodule Monty.Frameworks.EnvironmentUtils.TransformsMontyTest do
  @moduledoc """
  Translations of `tests/unit/frameworks/environment_utils/transforms_test.py`.

  Twelve cases, in Monty's order: three for `GaussianSmoothing`, four that a
  blur's constructor refuses what it must, two that an observation missing what
  the transform needs is an error rather than a no-op, and three properties of
  the blur.

  Two of Monty's cases drive a *public* method of its class: `get_padded_img`
  and `conv2d`. `get_padded_img(img, pad_type: "edge")` is `padded/2` here, and
  is asserted against Monty's own array; `conv2d` is listed below.

  The three properties are Monty's Hypothesis cases in `ExUnitProperties`: a
  solid picture blurs to itself, alpha is never touched, and total variation
  cannot rise.

  ## What could not be translated

  Half of `test_gaussian_smoothing` — the second image, the 4 × 4 ramp and the
  numbers it smooths to. Monty's case pads that image with `pad_type="empty"`,
  which is NaN, and filters it with `conv2d(padded, kernel_renorm=True)`, which
  drops the NaN taps and renormalises the kernel over the ones left. Neither
  exists here: Monty's own `call` pads with the edge and calls `scipy` directly,
  never `conv2d`, so the method its case pins has no caller in the transform it
  belongs to — and a mode with no caller is one this port cannot check. The
  half that the transform does perform, a picture of one value smoothing to
  that value, is translated above.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Monty.Frameworks.EnvironmentUtils.Transforms.GaussianBlurRGB
  alias Monty.Frameworks.EnvironmentUtils.Transforms.GaussianSmoothing
  alias Monty.Frameworks.EnvironmentUtils.Transforms.TransformContext

  @agent "agent_id_0"
  @sensor "agent_id_0" <> "_sensor_0"

  # Monty's `BLUR_KERNEL_SIZES`: auto (0) or odd, up to 15.
  @blur_kernel_sizes [0 | Enum.to_list(1..15//2)]

  defp context, do: %TransformContext{}

  defp observations(sensor_observation),
    do: %{@agent => %{@sensor => sensor_observation}}

  defp smooth(depth, options) do
    transform = GaussianSmoothing.new(Keyword.merge([agent_id: @agent], options))
    GaussianSmoothing.call(observations(%{"depth" => depth}), transform, context())
  end

  defp blurred_depth(depth, options), do: smooth(depth, options)[@agent][@sensor]["depth"]

  defp blurred_rgba(rgba, options) do
    transform = GaussianBlurRGB.new(Keyword.merge([agent_id: @agent], options))

    GaussianBlurRGB.call(observations(%{"rgba" => rgba}), transform, context())[@agent][
      @sensor
    ]["rgba"]
  end

  # `tests.unit.statistics.total_variation`: what the picture does from pixel to
  # pixel, summed over both axes and the three colour channels.
  defp total_variation(rgba) do
    colour = Enum.map(rgba, fn row -> Enum.map(row, &Enum.take(&1, 3)) end)
    horizontal = colour |> Enum.map(&adjacent_abs_sum/1) |> Enum.sum()
    vertical = colour |> transpose() |> Enum.map(&adjacent_abs_sum/1) |> Enum.sum()
    horizontal + vertical
  end

  defp adjacent_abs_sum(row) do
    row
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [left, right] ->
      Enum.zip(left, right) |> Enum.map(fn {a, b} -> abs(a - b) end)
    end)
    |> List.flatten()
    |> Enum.sum()
  end

  defp transpose(rows) do
    rows |> Enum.zip_with(& &1)
  end

  defp near?(first, second), do: abs(first - second) <= 1.0e-5

  describe "smoothing a depth image" do
    # test_create_kernel
    test "the kernel is Monty's, as the outer product of the vector the port holds" do
      kernel =
        GaussianSmoothing.new(agent_id: @agent, sigma: 2, kernel_width: 5).kernel

      # Monty's `test_create_kernel` ground truth, verbatim.
      ground_truth = [
        [0.02324684, 0.03382395, 0.03832756, 0.03382395, 0.02324684],
        [0.03382395, 0.04921356, 0.05576627, 0.04921356, 0.03382395],
        [0.03832756, 0.05576627, 0.06319146, 0.05576627, 0.03832756],
        [0.03382395, 0.04921356, 0.05576627, 0.04921356, 0.03382395],
        [0.02324684, 0.03382395, 0.03832756, 0.03382395, 0.02324684]
      ]

      assert length(kernel) == 5

      outer = for row <- kernel, do: for(column <- kernel, do: row * column)

      assert Enum.zip_with(outer, ground_truth, fn ours, theirs ->
               Enum.zip_with(ours, theirs, &near?/2) |> Enum.all?()
             end)
             |> Enum.all?()
    end

    # test_replication_padding
    test "a picture is padded by repeating its outermost row and column" do
      image = [[1, 2, 3], [4, 5, 6]]

      # Monty's ground truth, verbatim.
      ground_truth = [
        [1.0, 1.0, 1.0, 1.0, 2.0, 3.0, 3.0, 3.0, 3.0],
        [1.0, 1.0, 1.0, 1.0, 2.0, 3.0, 3.0, 3.0, 3.0],
        [1.0, 1.0, 1.0, 1.0, 2.0, 3.0, 3.0, 3.0, 3.0],
        [1.0, 1.0, 1.0, 1.0, 2.0, 3.0, 3.0, 3.0, 3.0],
        [4.0, 4.0, 4.0, 4.0, 5.0, 6.0, 6.0, 6.0, 6.0],
        [4.0, 4.0, 4.0, 4.0, 5.0, 6.0, 6.0, 6.0, 6.0],
        [4.0, 4.0, 4.0, 4.0, 5.0, 6.0, 6.0, 6.0, 6.0],
        [4.0, 4.0, 4.0, 4.0, 5.0, 6.0, 6.0, 6.0, 6.0]
      ]

      assert GaussianSmoothing.padded(image, 7) == ground_truth
    end

    # test_gaussian_smoothing (the half this port can translate)
    test "a picture of one value smooths to that value" do
      ones = List.duplicate(List.duplicate(1.0, 64), 64)

      smoothed = blurred_depth(ones, sigma: 15, kernel_width: 15)

      assert length(smoothed) == 64
      assert smoothed |> hd() |> length() == 64
      assert Enum.all?(List.flatten(smoothed), &(abs(&1 - 1.0) <= 1.0e-9))
    end
  end

  describe "a blur's parameters" do
    # test_negative_kernel_size_raises
    test "a negative kernel size is refused" do
      assert_raise ArgumentError, ~r/kernel_size must be non-negative/, fn ->
        GaussianBlurRGB.new(agent_id: @agent, kernel_size: -1)
      end
    end

    # test_even_kernel_size_raises
    test "an even kernel size is refused" do
      assert_raise ArgumentError, ~r/kernel_size must be odd or 0/, fn ->
        GaussianBlurRGB.new(agent_id: @agent, kernel_size: 4)
      end
    end

    # test_non_positive_sigma_with_auto_kernel_raises
    test "a kernel size of zero needs a positive sigma" do
      assert_raise ArgumentError, ~r/sigma must be positive when kernel_size is 0/, fn ->
        GaussianBlurRGB.new(agent_id: @agent, sigma: 0, kernel_size: 0)
      end
    end

    # test_empty_sensor_ids_raises
    test "naming no sensor at all is refused" do
      assert_raise ArgumentError, ~r/sensor_ids must not be empty/, fn ->
        GaussianBlurRGB.new(agent_id: @agent, sensor_ids: [])
      end
    end
  end

  describe "an observation the blur cannot use" do
    # test_sensor_id_not_in_agent
    test "a named sensor the agent did not report is an error" do
      transform =
        GaussianBlurRGB.new(agent_id: @agent, sensor_ids: [@sensor], sigma: 15, kernel_size: 15)

      assert_raise KeyError, ~r/not in the observations/, fn ->
        GaussianBlurRGB.call(%{@agent => %{}}, transform, context())
      end
    end

    # test_rgba_not_in_sensor_observations
    test "a sensor with no colour image is an error" do
      transform = GaussianBlurRGB.new(agent_id: @agent, sigma: 15, kernel_size: 15)

      assert_raise KeyError, ~r/no 'rgba'/, fn ->
        GaussianBlurRGB.call(observations(%{"depth" => [[1.0]]}), transform, context())
      end
    end
  end

  describe "what a blur cannot change" do
    # test_blur_solid_image_returns_identical
    property "a solid picture comes back solid, whatever the kernel" do
      check all(
              height <- integer(1..16),
              width <- integer(1..16),
              fill <- integer(0..255),
              sigma <- float(min: 0.1, max: 10.0),
              kernel_size <- member_of(@blur_kernel_sizes)
            ) do
        rgba = for _row <- 1..height, do: for(_pixel <- 1..width, do: List.duplicate(fill, 4))

        assert blurred_rgba(rgba, sigma: sigma, kernel_size: kernel_size) == rgba
      end
    end

    # test_blur_preserves_alpha
    property "the alpha channel is never touched" do
      check all({rgba, sigma, kernel_size} <- rgba_and_blur_params()) do
        alpha = for row <- rgba, do: for(pixel <- row, do: List.last(pixel))

        result = blurred_rgba(rgba, sigma: sigma, kernel_size: kernel_size)

        assert for(row <- result, do: for(pixel <- row, do: List.last(pixel))) == alpha
      end
    end

    # test_blur_reduces_total_variation
    property "total variation cannot rise" do
      check all({rgba, sigma, kernel_size} <- rgba_and_blur_params()) do
        input_variation = total_variation(rgba)

        # Monty's `assume(input_tv > 0.0)`: a solid picture has nothing to lower.
        if input_variation > 0.0 do
          result = blurred_rgba(rgba, sigma: sigma, kernel_size: kernel_size)

          assert total_variation(result) <= input_variation + 1.0e-9
        end
      end
    end
  end

  # Monty's `rgba_and_blur_params`: a seeded picture of any size, and parameters
  # the blur takes.
  defp rgba_and_blur_params do
    gen all(
          height <- integer(1..16),
          width <- integer(1..16),
          seed <- integer(0..4_294_967_295),
          sigma <- float(min: 0.1, max: 10.0),
          kernel_size <- member_of(@blur_kernel_sizes)
        ) do
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      rgba =
        for _row <- 1..height,
            do: for(_pixel <- 1..width, do: for(_channel <- 1..4, do: :rand.uniform() * 255.0))

      {rgba, sigma, kernel_size}
    end
  end
end
