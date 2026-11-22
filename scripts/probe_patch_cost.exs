# Where a step goes, function by function, in a real world.
#
#   MIX_ENV=test mix run scripts/probe_patch_cost.exs [experiment] [steps] [world]
#
# The third argument names the world, as in `probe_step_phases.exs`: `ex_mujoco`
# is the compiled one a run uses by default, `mujoco` the embedded interpreter.
#
# `probe_step_phases.exs` says the sensor module is the largest process in a
# step; this says which functions it is, because that is what decides whether the
# next change is a kernel, a data shape, or nothing.
#
# `tprof` with `rootset: :all`, as in `probe_step_profile.exs`: the sensor does
# its work in its own process, which the caller never names. Call counts and
# allocations are the numbers to read; the time column is inflated by the
# profiler itself (`docs/optimisation.md`).

alias Monty.Studio

Code.require_file("probe_support.exs", __DIR__)

experiment = System.argv() |> Enum.at(0, "base_config_10distinctobj_dist_agent")
steps = System.argv() |> Enum.at(1, "4") |> String.to_integer()
world = System.argv() |> Enum.at(2) |> then(&(&1 && String.to_existing_atom(&1)))

opened = ProbeSupport.setup(experiment, if(world, do: [world_simulator: world], else: []))
{:ok, run} = Studio.Run.start(opened.setup, steps: steps)
:ok = Studio.Run.set_ground_truth(run)
{:ok, _info, _observations, run} = Studio.Run.step(run)

step = fn -> Studio.Run.step(run) end

profile = fn type ->
  :tprof.profile(step, %{type: type, rootset: :all, report: {:total, {:measurement, :descending}}})
end

IO.puts("\n== words allocated ==")
IO.puts(profile.(:call_memory))

IO.puts("\n== scheduler time (the profiler inflates it; read the shares) ==")
IO.puts(profile.(:call_time))
