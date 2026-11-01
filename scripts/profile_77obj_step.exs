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

{first_us, {:ok, _info, _observations, run}} = :timer.tc(fn -> Run.step(run) end)
IO.puts("first step: #{Float.round(first_us / 1_000_000, 2)} s")

{second_us, {:ok, _info, _observations, run}} = :timer.tc(fn -> Run.step(run) end)
IO.puts("second step: #{Float.round(second_us / 1_000_000, 2)} s")

IO.puts("\nby function, the third step (microseconds):")
:eprof.start()
:eprof.profile(fn -> Run.step(run) end)
:eprof.analyze(:total, sort: :time)
:eprof.stop()

