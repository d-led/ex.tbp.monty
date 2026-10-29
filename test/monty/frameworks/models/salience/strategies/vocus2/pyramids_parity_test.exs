defmodule Monty.Frameworks.Models.Salience.Strategies.Vocus2.PyramidsParityTest do
  @moduledoc """
  The port answers what Monty answers, plane for plane.

  `scripts/record_monty_pyramids.py` ran Monty's own pyramid functions over an
  eight by eight image with structure at two sizes — a blob and a bright edge —
  and wrote down every plane they produced. These replay it: the resolutions
  chosen, the Gaussian pyramid, the centre and surround, the Laplacian, the
  combination of two pyramids, and the collapse back to one image.

  Tolerances are float32, because every plane went through OpenCV.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Pyramids.Pyramid

  @fixture Path.expand("../../../../../../fixtures/monty_pyramids.json", __DIR__)
  @float32 1.0e-4

  setup_all do
    {:ok, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "the resolutions chosen for an image are Monty's", %{fixture: fixture} do
    assert shapes(8, 8, nil) == fixture["octave_shapes"]["8x8"]
    assert shapes(8, 8, 2) == fixture["octave_shapes"]["8x8 max 2"]
    assert shapes(5, 9, nil) == fixture["octave_shapes"]["5x9"]
  end

  defp shapes(rows, columns, max_octaves) do
    rows
    |> then(&{&1, columns})
    |> Pyramids.octave_shapes(max_octaves)
    |> Enum.map(fn {row, column} -> [row, column] end)
  end

  test "the Gaussian pyramid is Monty's, plane for plane", %{fixture: fixture} do
    %{"sigma" => sigma, "n_scales" => scales, "expected" => expected} = fixture["gaussian"]

    pyramid = Pyramids.gaussian_pyramid(fixture["image"], sigma: sigma, n_scales: scales)

    # An eight by eight halves to one by one in four octaves, each with the
    # three scales asked for.
    assert Pyramid.shape(pyramid) == {4, 3}
    assert_close(planes(pyramid), expected)
  end

  test "a centre and its surround are Monty's", %{fixture: fixture} do
    %{"center" => center, "surround" => surround} = fixture["center_surround"]

    {port_center, port_surround} =
      Pyramids.center_surround(fixture["image"],
        center_sigma: 1.0,
        surround_sigma: 2.5,
        n_scales: 2
      )

    assert_close(planes(port_center), center)
    assert_close(planes(port_surround), surround)
  end

  test "the Laplacian pyramid is Monty's", %{fixture: fixture} do
    gaussian = Pyramids.gaussian_pyramid(fixture["image"], sigma: 1.0, n_scales: 3)

    assert_close(planes(Pyramids.laplacian(gaussian)), fixture["laplacian"]["expected"])
  end

  test "combining two pyramids by maximum is Monty's", %{fixture: fixture} do
    gaussian = Pyramids.gaussian_pyramid(fixture["image"], sigma: 1.0, n_scales: 3)

    assert_close(
      planes(Pyramids.combine_max([gaussian, gaussian])),
      fixture["combine_max"]["expected"]
    )
  end

  test "collapsing a pyramid by summing its planes is Monty's", %{fixture: fixture} do
    gaussian = Pyramids.gaussian_pyramid(fixture["image"], sigma: 1.0, n_scales: 3)

    collapsed = Pyramids.collapse(gaussian, fn planes -> Enum.reduce(planes, &add/2) end)

    assert_close([collapsed], [fixture["collapse_sum"]["expected"]])
  end

  defp planes(%Pyramid{planes: planes}), do: planes

  defp add(left, right) do
    Enum.zip_with([left, right], fn [left_row, right_row] ->
      Enum.zip_with([left_row, right_row], fn [left_value, right_value] ->
        left_value + right_value
      end)
    end)
  end

  # Every plane of every octave, compared number by number.
  defp assert_close(port, monty) do
    assert length(port) == length(monty)

    port
    |> Enum.zip(monty)
    |> Enum.each(fn {port_octave, monty_octave} ->
      assert length(port_octave) == length(monty_octave)
      assert_close_planes(port_octave, monty_octave)
    end)
  end

  defp assert_close_planes(port_planes, monty_planes) do
    port_planes
    |> Enum.zip(monty_planes)
    |> Enum.each(fn {port_plane, monty_plane} ->
      port_plane
      |> List.flatten()
      |> Enum.zip(List.flatten(monty_plane))
      |> Enum.each(fn {port_value, monty_value} ->
        assert_in_delta port_value, monty_value, @float32
      end)
    end)
  end
end
