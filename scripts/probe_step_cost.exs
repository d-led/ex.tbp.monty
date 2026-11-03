# What a step costs: time, reductions, and the garbage it makes.
#
#   MIX_ENV=test mix run scripts/probe_step_cost.exs [experiment] [steps]
#
# Three numbers, because one of them lies on its own. Wall time is the one that
# matters and the one this machine cannot be trusted with — an editor holding
# five busy processes turns a 0.6 s step into a 3 s one. Reductions count the
# work the BEAM actually scheduled, and reclaimed words count the garbage that
# work made; neither changes when the machine is busy. A step that is slow with
# few reductions is a step that is starved, not a step that is heavy.
#
# Both are counted over the whole VM rather than over one process, because a step
# is not one process: the coordinator, every sensor module and every learning
# module each do part of it. Which of them did the most is the question that
# decides what to optimise, so the largest movers are listed too.
#
# Measured this way on 2026-11-03, base_config_10distinctobj_dist_agent, six
# steps from a fresh run: 8.9 M reductions and 82 MB of reclaimed words per step,
# of which the learning module's server is 5.1 M, the two sensor modules 1.4 M,
# the caller's own process 1.2 M and the MuJoCo host 0.5 M. The same script read
# 22 M and 212 MB before the native kernels and the flat hypothesis set; those
# are the numbers to beat, not a promise.

alias Monty.Studio

defmodule ProbeStepCost do
  @moduledoc """
  Reductions per process, so a step's total can be attributed to the processes
  that did it rather than guessed at.

  A step is the coordinator, every sensor module, every learning module and
  whatever they hand work to; only the largest of those is worth a kernel. A pid
  that lived only during the step is not in both snapshots and is skipped.
  """

  def work do
    for pid <- Process.list(), into: %{} do
      {pid, :erlang.process_info(pid, [:reductions, :dictionary, :current_function])}
    end
  end

  def report(before, after_work, steps) do
    before
    |> Enum.flat_map(fn {pid, old} -> moved(pid, old, Map.get(after_work, pid), steps) end)
    |> Enum.sort(:desc)
    |> Enum.take(8)
    |> Enum.map_join("\n", fn {per_step, label} ->
      "    #{String.pad_leading("#{per_step}", 10)}  #{label}"
    end)
  end

  defp moved(_pid, _old, nil, _steps), do: []

  defp moved(_pid, old, new, steps) do
    [
      {div(Keyword.fetch!(new, :reductions) - Keyword.fetch!(old, :reductions), steps),
       label(new)}
    ]
  end

  # What a process *is*, not what it was doing: a GenServer between calls is
  # suspended in `gen_server:loop/7` and its `initial_call` is `proc_lib`, so
  # neither names it. OTP records the callback module in the process dictionary
  # as `"$initial_call"`; a plain spawn has no such entry and is named by the
  # module it was running instead.
  defp label(info) do
    case List.keyfind(Keyword.fetch!(info, :dictionary), :"$initial_call", 0) do
      {_key, {module, _function, _arity}} -> inspect(module)
      nil -> inspect(elem(Keyword.fetch!(info, :current_function), 0))
    end
  end
end

experiment = List.first(System.argv()) || "base_config_10distinctobj_dist_agent"
steps = String.to_integer(Enum.at(System.argv(), 1) || "6")

# `--profile` adds one more step under `tprof`, over every process it touches:
# this is the only probe that drives the world and the real sensor modules, so it
# is the only one whose profile can say what the sensor side costs.
profile? = "--profile" in System.argv()

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)

{:ok, run} = Studio.Run.start(opened.setup, steps: steps)
:ok = Studio.Run.set_ground_truth(run)

gc = fn ->
  {collections, words, _} = :erlang.statistics(:garbage_collection)
  {collections, words}
end

{collections_before, words_before} = gc.()
reductions = fn -> :erlang.statistics(:reductions) |> elem(0) end
reductions_before = reductions.()

# Reductions per process, so the total can be attributed: a step is the
# coordinator, every sensor module, every learning module and whatever they
# hand work to, and only one of those is worth writing a kernel for.
work_before = ProbeStepCost.work()
started = System.monotonic_time()

run =
  Enum.reduce(1..steps, run, fn _step, run ->
    {:ok, _info, _observations, run} = Studio.Run.step(run)
    run
  end)

elapsed = System.monotonic_time() - started
reductions_after = reductions.()
{collections_after, words_after} = gc.()
work_after = ProbeStepCost.work()

IO.puts("""
#{experiment}: #{steps} steps
  wall        #{round(System.convert_time_unit(elapsed, :native, :millisecond) / steps)} ms/step
  work        #{div(reductions_after - reductions_before, steps)} reductions/step
  garbage     #{div(words_after - words_before, steps * 125_000)} MB/step, \
#{collections_after - collections_before} collections

  who         reductions/step, largest first
#{ProbeStepCost.report(work_before, work_after, steps)}
""")

if profile? do
  IO.puts("\n== one more step, by function (words allocated) ==")

  :tprof.profile(
    fn -> Studio.Run.step(run) end,
    %{type: :call_memory, rootset: :all, report: {:total, {:measurement, :descending}}}
  )
  |> IO.puts()
end

Studio.Run.stop(run)
