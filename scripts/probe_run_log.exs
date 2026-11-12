# What a run's own log says about where its time went: the wall clock from the
# first step line to the last, the steps' own times, and the gap a step leaves
# behind — which is everything the studio does around the model.
#
#   mix run scripts/probe_run_log.exs priv/studio_runs/<id>

dir =
  case System.argv() do
    [dir] -> dir
    _ -> Mix.raise("usage: mix run scripts/probe_run_log.exs priv/studio_runs/<id>")
  end

lines = dir |> Path.join("run.log") |> File.read!() |> String.split("\n", trim: true)

# `07:22:41.637 07:22:41.629 step 7 · percepts patch · … · 89.3ms · …` — the
# first stamp is when the line was written, the number after the last dot is the
# step's own report of itself.
step = ~r/^(\d\d):(\d\d):(\d\d)\.(\d+) .*step (\d+) .*· (\d+(?:\.\d+)?)ms · /

to_ms = fn h, m, s, frac ->
  base = (String.to_integer(h) * 3600 + String.to_integer(m) * 60 + String.to_integer(s)) * 1000

  frac =
    frac |> String.pad_trailing(3, "0") |> String.slice(0, 3) |> String.to_integer()

  base + frac
end

steps =
  for line <- lines, match = Regex.run(step, line), into: [] do
    [_, h, m, s, frac, _number, own] = match

    %{
      at: to_ms.(h, m, s, frac),
      own: own |> Float.parse() |> elem(0)
    }
  end

first_at = steps |> List.first() |> Map.fetch!(:at)
last_at = steps |> List.last() |> Map.fetch!(:at)
wall = last_at - first_at
model = steps |> Enum.map(& &1.own) |> Enum.sum()

gaps =
  steps
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.map(fn [before, now] -> now.at - before.at - now.own end)

sorted = Enum.sort(gaps)

percentile = fn share ->
  Enum.at(sorted, min(div(length(sorted) * share, 100), length(sorted) - 1))
end

IO.puts("run #{Path.basename(dir)}")
IO.puts("  steps: #{length(steps)}")
IO.puts("  wall, first step line to last: #{Float.round(wall / 1000, 1)} s")
IO.puts("  the steps' own time: #{Float.round(model / 1000, 1)} s, #{Float.round(100 * model / wall, 1)} %")
IO.puts("  a step: #{Float.round(wall / length(steps), 1)} ms wall, #{Float.round(model / length(steps), 1)} ms own")

IO.puts(
  "  the gap around a step: median #{percentile.(50)} ms, 90th #{percentile.(90)} ms, worst #{List.last(sorted)} ms"
)
