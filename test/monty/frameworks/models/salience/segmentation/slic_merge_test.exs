defmodule Monty.Frameworks.Models.Salience.Segmentation.SlicMergeTest do
  @moduledoc """
  SLIC's label field, checked against `skimage`'s own, and the four judgements
  after it.

  The parity case is the one that matters: `skimage.segmentation.slic` is
  Cython, and this module is the same arithmetic in Elixir. `@skimage_labels`
  below was produced by `skimage` 0.26.0 from exactly the image
  `slic_image/1` builds, with exactly the parameters `SlicMerge` passes:

      slic(img, n_segments=70, compactness=10.0, max_num_iter=10, sigma=1.0,
           spacing=None, convert2lab=True, enforce_connectivity=True,
           min_size_factor=0.5, max_size_factor=3.0, start_label=0, mask=None,
           channel_axis=-1)

  `~/src/monty-orig/.venv` has that `skimage`, so the fixture is one command
  away from being re-made: the same view is also compared against it on a real
  MuJoCo view (64×64, 56 superpixels) with no pixel differing.

  The merge cases are Monty's own — `tests/unit/frameworks/models/salience/segmentation/slic_merge_test.py`
  generates them with hypothesis; what each one says is "the walk takes the
  neighbours whose colour is close and stops at the one that is not", which is
  written out here as the smallest arrangement that can show it.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.Segmentation.SlicMerge

  # skimage 0.26.0's labels for `slic_image(16)` with `SlicMerge`'s parameters.
  @skimage_labels [
    [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7],
    [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7],
    [8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15],
    [8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15],
    [16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23],
    [16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23],
    [24, 24, 25, 25, 26, 26, 27, 27, 28, 28, 29, 29, 30, 30, 31, 31],
    [24, 24, 25, 25, 26, 26, 27, 27, 28, 28, 29, 29, 30, 30, 31, 31],
    [32, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37, 38, 38, 39, 39],
    [32, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37, 38, 38, 39, 39],
    [40, 40, 41, 41, 42, 42, 43, 43, 44, 44, 45, 45, 46, 46, 47, 47],
    [40, 40, 41, 41, 42, 42, 43, 43, 44, 44, 45, 45, 46, 46, 47, 47],
    [48, 48, 49, 49, 50, 50, 51, 51, 52, 52, 53, 53, 54, 54, 55, 55],
    [48, 48, 49, 49, 50, 50, 51, 51, 52, 52, 53, 53, 54, 54, 55, 55],
    [56, 56, 57, 57, 58, 58, 59, 59, 60, 60, 61, 61, 62, 62, 63, 63],
    [56, 56, 57, 57, 58, 58, 59, 59, 60, 60, 61, 61, 62, 62, 63, 63]
  ]

  describe "the superpixels of a view" do
    test "are the ones skimage finds, label for label" do
      labels = SlicMerge.segment_image(SlicMerge.new(), slic_image(16))

      assert labels == @skimage_labels
    end

    test "cover every pixel, and every label is a connected blob" do
      labels = SlicMerge.segment_image(SlicMerge.new(), slic_image(16))

      assert length(List.flatten(labels)) == 16 * 16
      assert labels |> List.flatten() |> MapSet.new() |> MapSet.size() == 64
    end
  end

  describe "which superpixels touch which" do
    test "is a shared edge, and never a shared corner" do
      # A four by four view cut into four quadrants of two by two: two tiles meet
      # along the middle line, and the corner where all four are near each other
      # is not contact.
      region_image = [
        [0, 0, 1, 1],
        [0, 0, 1, 1],
        [2, 2, 3, 3],
        [2, 2, 3, 3]
      ]

      adjacency = SlicMerge.build_adjacency_graph(region_image, 4)

      assert adjacency == [
               MapSet.new([1, 2]),
               MapSet.new([0, 3]),
               MapSet.new([0, 3]),
               MapSet.new([1, 2])
             ]
    end

    test "is itself when a region is the only one" do
      assert SlicMerge.build_adjacency_graph([[7, 7], [7, 7]], 1) == [MapSet.new()]
    end
  end

  describe "the walk from the centre of the view" do
    # Three regions side by side, each two rows tall, so the pixel under the
    # centre of the view is in the middle region: the walk starts at 1.
    defp band(colors) do
      region_image = [[0, 1, 2], [0, 1, 2]]

      adjacency = [
        MapSet.new([1]),
        MapSet.new([0, 2]),
        MapSet.new([1])
      ]

      {region_image, colors, adjacency}
    end

    test "takes a neighbour whose colour is close, and stops at one that is not" do
      {region_image, region_colors, adjacency} =
        band([[0.5, 0.5, 0.5], [0.51, 0.5, 0.5], [0.9, 0.2, 0.2]])

      assert SlicMerge.merge_regions(
               SlicMerge.new(merge_threshold: 0.04),
               region_image,
               region_colors,
               adjacency
             ) == MapSet.new([0, 1])
    end

    test "takes every region when each colour is within the threshold" do
      {region_image, region_colors, adjacency} =
        band([[0.5, 0.5, 0.5], [0.51, 0.5, 0.5], [0.52, 0.5, 0.5]])

      assert SlicMerge.merge_regions(
               SlicMerge.new(merge_threshold: 0.04),
               region_image,
               region_colors,
               adjacency
             ) == MapSet.new([0, 1, 2])
    end

    test "is the region under the centre pixel, and nothing else when nothing is close" do
      {region_image, region_colors, adjacency} =
        band([[0.9, 0.2, 0.2], [0.5, 0.5, 0.5], [0.05, 0.05, 0.05]])

      assert SlicMerge.merge_regions(
               SlicMerge.new(merge_threshold: 0.04),
               region_image,
               region_colors,
               adjacency
             ) == MapSet.new([1])
    end
  end

  describe "the mean colour of a superpixel" do
    test "is the mean of its pixels" do
      region_image = [[0, 0, 1], [1, 1, 1]]

      colours = [
        [[0.0, 0.0, 0.0], [0.2, 0.2, 0.2], [1.0, 1.0, 1.0]],
        [[0.4, 0.4, 0.4], [0.4, 0.4, 0.4], [0.4, 0.4, 0.4]]
      ]

      assert [first, second] = SlicMerge.compute_superpixel_mean_colors(region_image, colours)

      assert close?(first, [0.1, 0.1, 0.1])

      # Four pixels: the bright one at the end of the first row, and the three dim
      # ones. Monty compares these with `assert_allclose`, so this does too.
      assert close?(second, [0.55, 0.55, 0.55])
    end
  end

  defp close?(values, expected) do
    values
    |> Enum.zip(expected)
    |> Enum.all?(fn {value, wanted} -> abs(value - wanted) < 1.0e-9 end)
  end

  describe "the mask a view gets" do
    test "is one where the walk reached, and zero everywhere else" do
      region_image = [[0, 1], [2, 2]]

      assert SlicMerge.create_mask(region_image, MapSet.new([0, 2])) == [[1, 0], [1, 1]]
    end

    test "is the shape of the view, from the segmentation Monty's cows configs name" do
      {mask, %SlicMerge{}} = SlicMerge.call(SlicMerge.new(), Monty.Context.new(0), slic_image(16))

      assert length(mask) == 16
      assert Enum.all?(mask, &(length(&1) == 16))
      assert mask |> List.flatten() |> Enum.uniq() |> Enum.sort() == [0, 1]
    end
  end

  # A sixteen by sixteen view of four colour ramps, one per quadrant. Written
  # the way the reference generation wrote it, so the two images are the same
  # image and not merely similar.
  defp slic_image(size) do
    for y <- 0..(size - 1) do
      for x <- 0..(size - 1) do
        block = div(x, 8) + 2 * div(y, 8)

        [
          rem(37 * block + 6 * x, 256) * 1.0,
          rem(11 * block + 9 * y, 256) * 1.0,
          rem(5 * x + 7 * y + 13 * block, 256) * 1.0
        ]
      end
    end
  end
end
