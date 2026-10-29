defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.ImagesParityTest do
  @moduledoc """
  The port answers what Monty answers, pixel for pixel.

  `vocus2/images.py` is arithmetic around OpenCV, and OpenCV is not a
  dependency of the port — it was measured. `scripts/record_monty_vocus2_images.py`
  ran Monty's own functions (and so OpenCV) over a few images and wrote down what
  they returned; this replays them.

  Two tolerances, because the operations are not equally reproducible:

    * the two opponent spaces are the same arithmetic on both sides, but OpenCV
      carries it in float32 and the port in float64, so they agree to float32
      precision;
    * the blur agrees to float32 precision for the same reason;
    * Lab goes through OpenCV's 8-bit lookup tables, which quantise, so the
      port's floating-point chain agrees to three units of 255 — measured over
      all 16,777,216 colours, and recorded as §1.12 in `docs/monty-bugs.md`.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images

  @fixture Path.expand("../../../../../../fixtures/monty_vocus2_images.json", __DIR__)

  @float32 1.0e-4
  @lab_quantisation 3.0 / 255.0
  setup_all do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    {:ok, colour: fixture["colour"], blur: fixture["blur"], resize: fixture["resize"]}
  end

  describe "colour spaces" do
    test "the opponent space agrees to float32 precision", %{colour: cases} do
      assert_conversions(cases, "opponent", &Images.rgb_to_opponent/1, @float32)
    end

    test "the CODI opponent space agrees to float32 precision", %{colour: cases} do
      assert_conversions(cases, "opponent_codi", &Images.rgb_to_opponent_codi/1, @float32)
    end

    test "Lab agrees to OpenCV's 8-bit quantisation", %{colour: cases} do
      assert_conversions(cases, "lab", &Images.rgb_to_lab/1, @lab_quantisation)
    end

    defp assert_conversions(cases, name, convert, tolerance) do
      for %{"name" => ^name, "rgba" => rgba, "expected" => expected} <- cases do
        assert close?(convert.(rgba), expected, tolerance)
      end
    end
  end

  describe "resize" do
    test "every interpolation agrees with OpenCV to float32 precision", %{resize: cases} do
      for %{"plane" => plane, "shape" => [rows, columns], "interpolation" => interpolation} =
            recorded <- cases do
        resized = Images.resize(plane, {rows, columns}, interpolation(interpolation))

        assert close?(resized, recorded["expected"], @float32)
      end
    end

    defp interpolation("area"), do: :area
    defp interpolation("cubic"), do: :cubic
  end

  describe "gaussian blur" do
    test "agrees with OpenCV to float32 precision", %{blur: cases} do
      for %{"plane" => plane, "sigma" => sigma, "truncate" => truncate, "expected" => expected} <-
            cases do
        blurred =
          if truncate == nil,
            do: Images.gaussian_blur(plane, sigma),
            else: Images.gaussian_blur(plane, sigma, truncate)

        assert close?(blurred, expected, @float32)
      end
    end
  end

  defp close?(actual, expected, tolerance) do
    shape(actual) == shape(expected) and
      actual
      |> List.flatten()
      |> Enum.zip(List.flatten(expected))
      |> Enum.all?(fn {port, monty} -> abs(port - monty) <= tolerance end)
  end

  defp shape([first | _rest] = rows) when is_list(first),
    do: {length(rows), length(first)}

  defp shape(flat), do: length(flat)
end
