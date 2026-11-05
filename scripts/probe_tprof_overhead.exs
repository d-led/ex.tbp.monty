# How much of what tprof reports is tprof?
#
# The step profile charges `Enum.map`'s loop 0.27 us per element, which would be
# most of a step. Either mapping a list really costs a quarter of a microsecond
# per element, or tprof's own tracing does. This measures the same work both
# ways: by the clock, and as tprof's table reports it.
#
#     MIX_ENV=test mix run scripts/probe_tprof_overhead.exs

defmodule ProbeTprofOverhead do
  @count 6_432
  @rounds 200

  def list, do: Enum.to_list(1..@count)

  def map_all(list), do: for(_ <- 1..@rounds, do: list |> Enum.map(&(&1 * 2)) |> length())
end

list = ProbeTprofOverhead.list()
elements = 200 * length(list)

IO.puts("mapping #{length(list)} elements, 200 rounds = #{elements} elements\n")

ProbeTprofOverhead.map_all(list)

{microseconds, _} = :timer.tc(fn -> ProbeTprofOverhead.map_all(list) end)

:io.format("by the clock: ~6.3f us per element (~6.1f ms for the lot)~n", [
  microseconds / elements,
  microseconds / 1000
])

IO.puts("\nwhat tprof makes of the same loop:\n")

IO.puts(
  :tprof.profile(
    fn -> ProbeTprofOverhead.map_all(list) end,
    %{type: :call_time, rootset: [self()], report: {:total, {:measurement, :descending}}}
  )
)

IO.puts("\nthe row above carries calls, total time and per call: divide the first into the second.")
