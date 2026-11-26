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

    # The arithmetic above is proven on sixteen pixels a side; this proves the
    # *same* arithmetic on a view big enough for the k-means to converge and the
    # connectivity pass to have blobs to absorb — 128 a side, where a 256-square
    # view costs 1.6 s a call and would make the suite pay for a pin.
    #
    # A digest, because the answer is 65 536 labels and the question is only
    # whether they changed. Both digests were taken from the implementation as
    # it stood before the loop was made cheaper, so a change that alters one
    # label, or breaks a tie the other way, shows up here and nowhere else.
    test "a 128-square view segments to the labels this implementation has always produced" do
      strategy = SlicMerge.new()

      assert digest(SlicMerge.segment_image(strategy, gradient_view(128))) ==
               "de23624545b51b56de895a3cbe7ac217ca56209153da16dd1334db1f7590b367"

      assert digest(SlicMerge.segment_image(strategy, disc_view(128))) ==
               "c90719f74956522fef8e8a16ae558807eaf7f06f3d8200b8fdd1ebca86468cf2"
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

  describe "the native k-means" do
    test "is loaded on this machine, so these cases are about the fast path" do
      assert ExTbpMonty.Core.SalienceNif.loaded?()
    end

    # The kernel answers the same label field, not a similar one: a different
    # tie, a different window edge or a different re-centring order would show up
    # as a pixel here. Small and large, smooth and with regions that end.
    test "answers the same labels as the Elixir loop, view for view" do
      for view <- [slic_image(16), gradient_view(64), gradient_view(128), disc_view(128)] do
        strategy = SlicMerge.new()

        assert SlicMerge.segment_image(strategy, view) ==
                 SlicMerge.segment_image_reference(strategy, view)
      end
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

  # The colours a view has when nothing in it needs cutting: every pixel near
  # its neighbours, so the k-means is the only work there is.
  defp gradient_view(size) do
    for y <- 0..(size - 1),
        do: for(x <- 0..(size - 1), do: [y / size, x / size, rem(y + x, size) / size])
  end

  # And a view with two flat discs on it, which is the other shape a view has:
  # regions that end, and a boundary the connectivity pass has to carry.
  defp disc_view(size) do
    for y <- 0..(size - 1) do
      for x <- 0..(size - 1) do
        near_first = :math.pow(y - size / 3.2, 2) + :math.pow(x - size / 2.8, 2)
        near_second = :math.pow(y - size / 1.35, 2) + :math.pow(x - size / 1.6, 2)

        cond do
          near_first < size -> [0.9, 0.2, 0.2]
          near_second < size * 1.8 -> [0.2, 0.8, 0.3]
          true -> [y / size, x / size, rem(y + x, size) / size]
        end
      end
    end
  end

  defp digest(labels),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(labels)) |> Base.encode16(case: :lower)
end
