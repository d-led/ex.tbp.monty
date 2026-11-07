# What the learning module's hot calls cost, and how much of a step they are.
#
#   MIX_ENV=test mix run scripts/probe_hypothesis_cost.exs
#
# `probe_step_profile.exs` gives call counts per function and the words each
# allocates, but not the reductions, and reductions are the currency a step is
# measured in (`docs/speed.md`). This costs each of the hot primitives on
# representative arguments, so the call count from the profile turns into a share
# of the step, and the loop worth replacing with a batched kernel is named by
# arithmetic rather than by its word count.
#
# Call counts per step, from `probe_step_profile.exs` on the ten-object config,
# are quoted beside each measurement so a stale one is visible. That profile ran
# three steps, so its counts are divided by three here.

alias ExTbpMonty.MatcherNif
alias Monty.Geometry

defmodule ProbeHypothesisCost do
  @doc "Reductions a function costs per call, over `times` calls."
  def per_call(times, fun) do
    # Warm the code path, then count: the first call pays for loading, not for
    # the work being measured. The result is dropped and not sized — sizing it
    # costs about twenty reductions, which is more than `Geometry.dot/2` itself
    # and would be measured instead of it.
    _ = Enum.each(1..50, fn _ -> fun.() end)
    :erlang.garbage_collect()
    before = reductions()
    _ = Enum.each(1..times, fn _ -> fun.() end)
    after_count = reductions()
    div(after_count - before, times)
  end

  def reductions, do: :erlang.statistics(:reductions) |> elem(0)

  @doc "The share of a step, given a per-call cost and how many calls a step makes."
  def share(per_call, calls_per_step, step_reductions \\ 7_101_344) do
    per_step = per_call * calls_per_step
    {per_step, Float.round(per_step / step_reductions * 100, 2)}
  end
end

# A hypothesis pose is a 3x3 matrix of floats, as `Hypotheses.pose/2` answers.
pose = [[0.12, -0.98, 0.03], [0.99, 0.121, -0.02], [0.01, 0.05, 0.998]]
# Two 3-vectors as `Geometry.dot/2` takes them: a node's direction and the
# sensed direction.
a = [0.123, -0.456, 0.789]
b = [0.311, 0.644, -0.211]
# Three f64 little-endian, as a kernel answers one hypothesis's worth.
window = <<1.5::float-64-little, 2.5::float-64-little, 3.5::float-64-little>>

dot = ProbeHypothesisCost.per_call(200_000, fn -> Geometry.dot(a, b) end)
transpose = ProbeHypothesisCost.per_call(100_000, fn -> Geometry.transpose(pose) end)
decode = ProbeHypothesisCost.per_call(100_000, fn -> MatcherNif.decode(window) end)

IO.puts("reductions per call, and the share of a 7.1 M-reduction step they are")

rows = [
  {"Geometry.dot/2", dot, 19_296},
  {"Geometry.transpose/1", transpose, 4_325},
  {"MatcherNif.decode/1 (3 values)", decode, 27_902}
]

Enum.each(rows, fn {label, per_call, calls} ->
  {per_step, percent} = ProbeHypothesisCost.share(per_call, calls)

  IO.puts(
    "  #{String.pad_trailing(label, 32)} #{String.pad_leading(Integer.to_string(per_call), 4)} red/call" <>
      "  × #{String.pad_leading(Integer.to_string(calls), 7)} calls" <>
      "  = #{String.pad_leading(Integer.to_string(per_step), 9)} (#{percent}%)"
  )
end)

{sum, _} = rows |> Enum.map(fn {_label, per_call, calls} -> per_call * calls end) |> Enum.sum() |> then(&{&1, nil})
IO.puts("  the three together:              #{sum} of 7 101 344 (#{Float.round(sum / 7_101_344 * 100, 2)}%)")