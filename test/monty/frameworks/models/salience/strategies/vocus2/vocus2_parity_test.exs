defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.Vocus2ParityTest do
  @moduledoc """
  The port answers what Monty answers, pixel by pixel.

  `scripts/record_monty_vocus2.py` ran Monty's own VOCUS2 over a 32 by 32 view —
  a bright blob, a dark corner and a hard edge — and over a depth map with a near
  step and an empty pixel, and wrote down the maps it answered. These replay
  them: the colour channel, the depth channel, the orientation channel (from
  Monty's own centre pyramid, so the pyramid is not under test here), the whole
  strategy, and the operating limits' verdicts.

  Tolerances are float32: every map went through blurring, resizing and Gabor
  filtering in OpenCV.
  """

  use ExUnit.Case, async: true

  alias Monty.Context

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.{
    ColorChannelSalience,
    DepthSalience,
    NoOperatingLimits,
    OrientationSalience,
    SafeOperatingLimits
  }

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  @fixture Path.expand("../../../../../../fixtures/monty_vocus2.json", __DIR__)
  @float32 1.0e-4
  @normalised 1.0e-3

  setup_all do
    {:ok, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  defp context, do: Context.new(0)

  test "a colour channel's salience map is Monty's", %{fixture: fixture} do
    %{"image" => image, "map" => expected, "center_pyramid" => expected_center} =
      fixture["color"]

    salience =
      ColorChannelSalience.new(
        center_sigma: 2.0,
        surround_sigma: 3.0,
        n_scales: 2,
        operating_limits: NoOperatingLimits.new()
      )

    {map, center} = ColorChannelSalience.process(salience, context(), image)

    assert_close(map, expected)
    assert_close_planes(center, expected_center)
  end

  test "a depth channel's salience map is Monty's", %{fixture: fixture} do
    %{"image" => image, "map" => expected} = fixture["depth"]

    salience =
      DepthSalience.new(
        center_sigma: 2.0,
        surround_sigma: 3.0,
        n_scales: 2,
        operating_limits: NoOperatingLimits.new()
      )

    assert_close(DepthSalience.process(salience, context(), image), expected)
  end

  test "the Gabor kernels are Monty's, kernel for kernel", %{fixture: fixture} do
    %{"period" => period, "kernels" => expected} = fixture["orientation"]

    assert_close_kernels(OrientationSalience.new(period: period).kernels, expected)
  end

  test "the orientation salience map is Monty's", %{fixture: fixture} do
    %{"period" => period, "map" => expected, "pyramid" => %{"octaves" => center}} =
      fixture["orientation"]

    salience = OrientationSalience.new(period: period)
    pyramid = Pyramid.new(center)

    assert_close(OrientationSalience.process(salience, context(), pyramid), expected)
  end

  test "the whole strategy's salience map is Monty's", %{fixture: fixture} do
    %{"rgba" => rgba, "depth" => depth, "map" => expected} = fixture["strategy"]
    %{"image" => channel} = fixture["color"]

    strategy =
      Vocus2.new(
        color:
          ColorChannelSalience.new(
            center_sigma: 2.0,
            surround_sigma: 3.0,
            n_scales: 2,
            operating_limits: NoOperatingLimits.new()
          ),
        depth:
          DepthSalience.new(
            center_sigma: 2.0,
            surround_sigma: 3.0,
            n_scales: 2,
            operating_limits: NoOperatingLimits.new()
          ),
        orientation: OrientationSalience.new(period: 4.0)
      )

    # The fixture's image is grey apart from the view's structure, so the
    # converter's opponent channels are derived from it rather than invented.
    assert is_list(channel)

    assert_close(Vocus2.call(strategy, context(), rgba, depth), expected, @normalised)
  end

  test "the operating limits give Monty's verdicts", %{fixture: fixture} do
    limits = SafeOperatingLimits.new()

    for %{"min_image_dim_size" => size, "center_sigma" => center, "surround_sigma" => surround} =
          recorded <- fixture["limits"] do
      verdict =
        limits.__struct__.validate(limits, size, center, surround)

      assert kind(verdict) == kind(recorded["error"]),
             "for size #{size} with sigmas #{center}/#{surround}: " <>
               "Monty said #{inspect(recorded["error"])}, the port said #{inspect(verdict)}"
    end
  end

  # Monty's messages are Python-formatted floats; the verdict is what matters,
  # and which of the three rejections fired.
  defp kind(nil), do: :ok
  defp kind(:ok), do: :ok

  defp kind({:error, "Surround sigma must be greater than or equal to center_sigma" <> _}),
    do: :separation

  defp kind({:error, "When smallest image dimension is" <> rest}) do
    if String.contains?(rest, "Center sigma"), do: :center, else: :surround
  end

  defp kind(message) when is_binary(message) do
    cond do
      String.starts_with?(message, "Surround sigma must be greater") -> :separation
      String.contains?(message, "Center sigma") -> :center
      true -> :surround
    end
  end

  defp assert_close(port, monty, tolerance \\ @float32) do
    assert length(port) == length(monty)
    assert length(hd(port)) == length(hd(monty))

    port
    |> List.flatten()
    |> Enum.zip(List.flatten(monty))
    |> Enum.each(fn {port_value, monty_value} ->
      assert_in_delta port_value, monty_value, tolerance
    end)
  end

  defp assert_close_planes(%Pyramid{} = pyramid, monty) do
    assert length(pyramid.planes) == length(monty)

    pyramid.planes
    |> Enum.zip(monty)
    |> Enum.each(fn {port_octave, monty_octave} ->
      port_octave
      |> Enum.zip(monty_octave)
      |> Enum.each(fn {port_plane, monty_plane} -> assert_close(port_plane, monty_plane) end)
    end)
  end

  defp assert_close_kernels(port, monty) do
    assert Enum.sort(Map.keys(port)) == Enum.sort(Map.keys(monty))

    Enum.each(monty, fn {name, kernel} -> assert_close(Map.fetch!(port, name), kernel) end)
  end
end
