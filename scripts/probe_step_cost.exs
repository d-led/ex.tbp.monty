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
# module each do part of it.
#
# Measured this way on 2026-11-02, base_config_10distinctobj_dist_agent, six
# steps from a fresh run: about 22 M reductions and 212 MB of reclaimed words per
# step, of which the learning module's matching step was 15 M and 123 MB, the
# sensor modules 4 M and 52 MB, and the neighbour pass 2 M and 34 MB.

alias Monty.Studio

experiment = List.first(System.argv()) || "base_config_10distinctobj_dist_agent"
steps = String.to_integer(Enum.at(System.argv(), 1) || "6")

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
started = System.monotonic_time()

run =
  Enum.reduce(1..steps, run, fn _step, run ->
    {:ok, _info, _observations, run} = Studio.Run.step(run)
    run
  end)

elapsed = System.monotonic_time() - started
reductions_after = reductions.()
{collections_after, words_after} = gc.()

IO.puts("""
#{experiment}: #{steps} steps
  wall        #{round(System.convert_time_unit(elapsed, :native, :millisecond) / steps)} ms/step
  work        #{div(reductions_after - reductions_before, steps)} reductions/step
  garbage     #{div(words_after - words_before, steps * 125_000)} MB/step, \
#{collections_after - collections_before} collections
""")

Studio.Run.stop(run)
