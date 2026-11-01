# Times one learning-module step of a 77-object experiment, and says where the
# time went.
#
#   mix run scripts/profile_77obj_step.exs
#
# Not part of the suite: it needs the exported pretrained library and a real
# YCB mesh set, and it answers a question about speed rather than behaviour. The
# totals are this machine's, so read the *shape* of the profile — which function
# is doing the work — rather than the seconds.

alias Monty.Studio

alias Monty.Studio.{Run, Setup}

{:ok, opened} = Studio.open("base_77obj_dist_agent")
{:ok, run} = Run.start(opened.setup, steps: 12)

IO.puts("#{length(Setup.objects(opened.setup))} objects in the memory")

# A step costs more once the module has hypotheses to weigh, so the first few
# steps are timed and the profile is taken on one that is carrying evidence.
{totals, run} =
  Enum.map_reduce(1..6, run, fn step, run ->
    {us, {:ok, _info, _observations, run}} = :timer.tc(fn -> Run.step(run) end)
    IO.puts("step #{step}: #{Float.round(us / 1_000, 1)} ms")
    {us, run}
  end)

IO.puts("mean: #{Float.round(Enum.sum(totals) / length(totals) / 1_000, 1)} ms")

IO.puts("\nby function, one more step (microseconds):")
:eprof.start()
:eprof.profile(fn -> Run.step(run) end)
:eprof.analyze(:total, sort: :time)
:eprof.stop()

