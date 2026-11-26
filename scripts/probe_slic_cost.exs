# What a salience step costs, stage by stage, on a view of the size the cows
# configs give it.
#
#   MIX_ENV=test mix run --no-start scripts/probe_slic_cost.exs [size] [sigma]
#
# `probe_sensor_cost.exs` says a cows step is 96.7 % `view_finder` — the
# `SalienceSM`. This splits that sensor's own work: the colour conversion, the
# Gaussian, and the SLIC k-means, each timed on the same 256x256 view, so the
# next change can be aimed at the stage that holds the seconds.
#
# The view is synthetic and cost-constant (a gradient whose colours vary across
# the image), because the question is what the arithmetic costs, not what a
# particular cow looks like. Three readings each, interleaved, on a warm VM.
#
# `--no-start`: nothing here needs the application or the database, and starting
# it would put Postgres' ownership timeout on a long probe.

alias Monty.Frameworks.Models.Salience.Segmentation.SlicMerge
alias Monty.Frameworks.Models.Salience.Strategies.Vocus2.Images

size = System.argv() |> List.first() |> then(&(&1 && String.to_integer(&1))) || 256
sigma = 1.0
truncate = 4.0

view =
  for row <- 0..(size - 1) do
    for column <- 0..(size - 1) do
      [row / size, column / size, rem(row + column, size) / size]
    end
  end

# `prepared_lab/1`'s first half: rescale the colours to fill `[0, 1]` (what
# `img_as_float` does), which `rgb_to_lab` then reads.
scaled =
  Enum.map(view, fn row ->
    Enum.map(row, fn pixel -> Enum.map(pixel, &(&1 * 255.0)) end)
  end)

plane =
  for row <- scaled do
    for [lightness | _rest] <- row, do: lightness
  end

strategy = SlicMerge.new()

time = fn label, work ->
  readings =
    for _ <- 1..3 do
      {microseconds, value} = :timer.tc(work)
      {Float.round(microseconds / 1000, 1), value}
    end

  best = readings |> Enum.map(&elem(&1, 0)) |> Enum.min()
  IO.puts("#{label}: #{best} ms (three readings: #{Enum.map_join(readings, ", ", &elem(&1, 0))})")
  readings |> List.last() |> elem(1)
end

_ = time.("warm-up: rgb_to_lab", fn -> Images.rgb_to_lab(scaled) end)
_ = time.("rgb_to_lab", fn -> Images.rgb_to_lab(scaled) end)

_ =
  time.("gaussian_blur, one channel (sigma #{sigma}, truncate #{truncate})", fn ->
    Images.gaussian_blur(plane, sigma, truncate)
  end)

_ = time.("segment_image (the whole SLIC)", fn -> SlicMerge.segment_image(strategy, view) end)
