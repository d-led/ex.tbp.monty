# Where a view's segmentation spends its time, stage by stage — measured warm.
#
#   MIX_ENV=test mix run --no-start scripts/probe_segment_stages.exs [size]
#
# `probe_slic_cost.exs` splits the sensor into colour, blur and k-means. This
# goes one level down, into the five judgements `SlicMerge.call/3` makes on a
# view of the size the cows configs give it — the labels, the region colours,
# the adjacency, the walk and the mask.
#
# **Each stage runs three times before it is timed, and its cost is the smallest
# of seven readings.** One reading of a stage that allocates lists is the
# arithmetic plus whatever the collector was doing: an earlier version of this
# probe read three 256-square blurs at 43.6 ms where the same work, warmed,
# measures 19.5. A stage's rank is only worth having if the number under it is
# the stage's own.
#
# The view is the synthetic gradient `probe_slic_cost.exs` uses, so the numbers
# are the arithmetic's and not one cow's.

alias Monty.Frameworks.Models.Salience.Segmentation.SlicMerge

size = System.argv() |> List.first() |> then(&(&1 && String.to_integer(&1))) || 256
strategy = SlicMerge.new()

view =
  for row <- 0..(size - 1) do
    for column <- 0..(size - 1) do
      [row / size, column / size, rem(row + column, size) / size]
    end
  end

# A live fixture per stage: what the stage after it reads.
labels = SlicMerge.segment_image(strategy, view)
colours = SlicMerge.extract_region_colors(view, labels)
adjacency = SlicMerge.build_adjacency_graph(labels, length(colours))
accepted = SlicMerge.merge_regions(strategy, labels, colours, adjacency)

time = fn label, work ->
  for _ <- 1..3, do: work.()
  readings = for _ <- 1..7, do: elem(:timer.tc(work), 0) / 1000

  IO.puts(
    "#{String.pad_trailing(label, 58)} #{String.pad_leading(Float.to_string(Float.round(Enum.min(readings), 1)), 6)} ms"
  )
end

_ = time.("segment_image (SLIC: Lab, blur, k-means, connectivity)", fn -> SlicMerge.segment_image(strategy, view) end)
_ = time.("extract_region_colors (Lab + per-region mean)", fn -> SlicMerge.extract_region_colors(view, labels) end)
_ = time.("build_adjacency_graph (contacts + transpose)", fn -> SlicMerge.build_adjacency_graph(labels, length(colours)) end)
_ = time.("merge_regions (the walk from the centre)", fn -> SlicMerge.merge_regions(strategy, labels, colours, adjacency) end)
_ = time.("create_mask (a mask of ones and zeros)", fn -> SlicMerge.create_mask(labels, accepted) end)
_ = time.("the whole call/3", fn -> SlicMerge.call(strategy, nil, view) end)
