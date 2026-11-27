defmodule Monty.Frameworks.Models.Salience.Segmentation.SlicMergeMontyTest do
  @moduledoc """
  Monty's own cases for `SlicMerge`, translated.

  Each test names the case in
  `tests/unit/frameworks/models/salience/segmentation/slic_merge_test.py` it
  translates. Monty's merge class patches the five steps and asserts the chain's
  arguments with mocks; Elixir has no mocks here and should not want them, so the
  same claim is made by recomposing the chain the way `call/3` does and
  comparing. What the mocks prove is that each step is handed the previous
  step's answer — that is what `test_segments_image` asserts, once for all five.

  A name that appears twice in Monty's file — once as a mock-wiring case, once as
  a property case over generated tiles — is translated once, and the test says
  which content it covers.

  These are translations, not intent: `slic_merge_test.exs` beside this file is
  the hand-written half, and the `skimage` fixture there is the arithmetic's
  evidence.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.Salience.Segmentation.SlicMerge
  alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images

  # A view with a gradient across it, so SLIC has colours to split on and the
  # cases do not depend on a fixture file.
  defp view(size) do
    for row <- 0..(size - 1) do
      for column <- 0..(size - 1) do
        [div(column * 255, size), div(row * 255, size), 128]
      end
    end
  end

  defp chain(strategy, rgb) do
    region_image = SlicMerge.segment_image(strategy, rgb)
    region_colors = SlicMerge.extract_region_colors(rgb, region_image)
    adjacency = SlicMerge.build_adjacency_graph(region_image, length(region_colors))
    accepted = SlicMerge.merge_regions(strategy, region_image, region_colors, adjacency)

    {region_image, region_colors, adjacency, accepted}
  end

  # test_segments_image
  test "the answer is the five steps, in Monty's order" do
    strategy = SlicMerge.new()
    rgb = view(16)
    {region_image, _colors, _adjacency, accepted} = chain(strategy, rgb)

    assert SlicMerge.call(strategy, Monty.Context.new(42), rgb) ==
             {SlicMerge.create_mask(region_image, accepted), strategy}
  end

  # test_extracts_region_colors
  test "the adjacency has one entry for every region colour" do
    strategy = SlicMerge.new()
    rgb = view(16)
    {region_image, region_colors, _adjacency, _accepted} = chain(strategy, rgb)

    assert length(SlicMerge.build_adjacency_graph(region_image, length(region_colors))) ==
             length(region_colors)
  end

  # test_builds_adjacency_graph
  test "the walk follows the adjacency it is handed, and nothing else" do
    # Two regions side by side, the same colour: joined by the graph they are one
    # region, and with an empty graph the walk stays where it started.
    region_image = [[0, 0, 1], [0, 0, 1], [1, 1, 1]]
    colors = [[0.5, 0.5, 0.5], [0.5, 0.5, 0.5]]
    graph = SlicMerge.build_adjacency_graph(region_image, 2)

    assert SlicMerge.merge_regions(SlicMerge.new(), region_image, colors, graph) ==
             MapSet.new([0, 1])

    assert SlicMerge.merge_regions(SlicMerge.new(), region_image, colors, [
             MapSet.new(),
             MapSet.new()
           ]) == MapSet.new([0])
  end

  # test_merges_regions
  test "a neighbour within the threshold joins the region, one beyond it does not" do
    # The walk starts at the region covering the image's centre, so region 0 has
    # to surround it for the case to be about the threshold and not the seed.
    region_image = [
      [0, 0, 0],
      [0, 0, 1],
      [0, 0, 0]
    ]

    adjacency = [MapSet.new([1]), MapSet.new([0])]

    close = [[0.5, 0.5, 0.5], [0.51, 0.5, 0.5]]
    far = [[0.1, 0.1, 0.1], [0.9, 0.9, 0.9]]

    assert SlicMerge.merge_regions(SlicMerge.new(), region_image, close, adjacency) ==
             MapSet.new([0, 1])

    assert SlicMerge.merge_regions(SlicMerge.new(), region_image, far, adjacency) ==
             MapSet.new([0])
  end

  # test_creates_mask_of_accepted_regions
  test "a mask is one where the region was accepted, and zero where it was not" do
    region_image = [[0, 0, 1], [0, 0, 1], [1, 1, 1]]

    assert SlicMerge.create_mask(region_image, MapSet.new([0])) == [
             [1, 1, 0],
             [1, 1, 0],
             [0, 0, 0]
           ]
  end

  # test_creates_mask
  test "a mask is the view's shape, and its ones are the accepted regions" do
    region_image = [[0, 1], [2, 2]]
    mask = SlicMerge.create_mask(region_image, MapSet.new([1, 2]))

    assert mask == [[0, 1], [1, 1]]
  end

  # test_invokes_slic_with_configured_parameters
  test "the parameters a strategy carries are the ones the segmentation uses" do
    rgb = view(16)
    coarse = SlicMerge.new(n_seeds: 4, compactness: 30.0, max_iter: 1, sigma: 0.0)
    fine = SlicMerge.new()

    assert SlicMerge.segment_image(coarse, rgb) != SlicMerge.segment_image(fine, rgb)

    # And the settings reach the kernel's arithmetic, not just its arguments: the
    # native path and the Elixir reference agree under them.
    assert SlicMerge.segment_image(coarse, rgb) ==
             SlicMerge.segment_image_reference(coarse, rgb)
  end

  # test_builds_adjacency_graph_for_a_square_grid_of_unique_regions
  test "a square grid of unique regions is adjacent to its edge neighbours only" do
    region_image = [
      [0, 0, 1, 1],
      [0, 0, 1, 1],
      [2, 2, 3, 3],
      [2, 2, 3, 3]
    ]

    graph = SlicMerge.build_adjacency_graph(region_image, 4)

    assert Enum.at(graph, 0) == MapSet.new([1, 2])
    assert Enum.at(graph, 1) == MapSet.new([0, 3])
    assert Enum.at(graph, 2) == MapSet.new([0, 3])
    assert Enum.at(graph, 3) == MapSet.new([1, 2])
  end

  # test_converts_to_normalized_lab_image
  test "the region colours are the mean colours of the image in Lab, over 255" do
    strategy = SlicMerge.new()
    rgb = view(16)
    {region_image, region_colors, _adjacency, _accepted} = chain(strategy, rgb)

    assert region_colors ==
             SlicMerge.compute_superpixel_mean_colors(region_image, Images.rgb_to_lab(rgb))
  end

  # test_computes_superpixel_mean_colors
  test "filling a region with its colour and taking the mean gives the colour back" do
    # Monty's case builds the merge image from known colours and asserts the
    # means are those colours; the pixels of a region are all equal, so the
    # arithmetic is exact.
    region_image = [[0, 0], [1, 1]]
    colors = [[0.25, 0.5, 0.75], [1.0, 0.5, 0.0]]

    merge_image =
      for row <- region_image do
        for label <- row, do: Enum.at(colors, label)
      end

    assert SlicMerge.compute_superpixel_mean_colors(region_image, merge_image) == colors
  end
end
