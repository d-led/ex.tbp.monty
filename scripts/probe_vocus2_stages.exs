# Where a view's salience score spends its time, stage by stage — measured warm.
#
#   MIX_ENV=test mix run --no-start scripts/probe_vocus2_stages.exs [size]
#
# `probe_sensor_cost.exs` and `probe_segment_stages.exs` split the sensor and its
# segmentation. This is the other half of a salience step: `Vocus2.call/4` — the
# alpha drop, the colour conversion, the three channel pyramids, and the combine
# and normalise — on a view of the size the cows configs give it.
#
# Each stage runs three times before it is timed and answers the smallest of
# seven readings, because a stage that allocates 65 536 lists reads its own cost
# only when the collector is not in the middle of one.

alias Monty.Frameworks.Models.Salience.Strategies.Vocus2
alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.{
  ColorChannelSalience,
  NoOperatingLimits
}

size = System.argv() |> List.first() |> then(&(&1 && String.to_integer(&1))) || 256
ctx = Monty.Context.new(:probe)

rgba =
  for row <- 0..(size - 1) do
    for column <- 0..(size - 1), do: [row / size, column / size, rem(row + column, size) / size, 1.0]
  end

depth = for _ <- 0..(size - 1), do: for(_ <- 0..(size - 1), do: 1.0)

channel =
  ColorChannelSalience.new(
    center_sigma: 1.0,
    surround_sigma: 3.0,
    n_scales: 2,
    operating_limits: NoOperatingLimits.new()
  )

strategy = Vocus2.new(color: channel)

rgb = for row <- rgba, do: Enum.map(row, &Enum.take(&1, 3))
opponent = Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images.rgb_to_opponent(rgb)

planes =
  {lightness, other_a, other_b} =
    Enum.reduce(opponent, {[], [], []}, fn row, {l, a, b} ->
      {l_row, a_row, b_row} =
        Enum.reduce(row, {[], [], []}, fn [lv, av, bv], {l_row, a_row, b_row} ->
          {[lv | l_row], [av | a_row], [bv | b_row]}
        end)

      {[Enum.reverse(l_row) | l], [Enum.reverse(a_row) | a], [Enum.reverse(b_row) | b]}
    end)

_ = {lightness, other_a, other_b}

measure = fn label, work ->
  for _ <- 1..3, do: work.()
  readings = for _ <- 1..7, do: elem(:timer.tc(work), 0) / 1000

  IO.puts(
    "#{String.pad_trailing(label, 52)} #{String.pad_leading(Float.to_string(Float.round(Enum.min(readings), 1)), 6)} ms"
  )
end

_ = measure.("drop the alpha channel (a 3-list a pixel)", fn -> for row <- rgba, do: Enum.map(row, &Enum.take(&1, 3)) end)
_ = measure.("rgb_to_opponent (the colour space)", fn -> Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images.rgb_to_opponent(rgb) end)

_ =
  measure.("three planes out of the image", fn ->
    Enum.reduce(opponent, {[], [], []}, fn row, {l, a, b} ->
      {l_row, a_row, b_row} =
        Enum.reduce(row, {[], [], []}, fn [lv, av, bv], {l_row, a_row, b_row} ->
          {[lv | l_row], [av | a_row], [bv | b_row]}
        end)

      {[Enum.reverse(l_row) | l], [Enum.reverse(a_row) | a], [Enum.reverse(b_row) | b]}
    end)
  end)

_ = measure.("one channel (pyramid, surround, mean, collapse)", fn -> ColorChannelSalience.process(channel, ctx, lightness) end)

_ =
  measure.("the whole Vocus2.call/4", fn ->
    Vocus2.call(strategy, ctx, rgba, depth)
  end)
