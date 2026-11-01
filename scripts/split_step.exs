# How much of a step is the world and how much is the learning module: the world
# is stepped on its own, then whole steps are taken, and the difference is what
# the modules cost.
#
#   MONTY_MODELS=… mix run scripts/split_step.exs [experiment]

alias Monty.Experiment.Environment.Interface
alias Monty.Studio
alias Monty.Studio.{Run, Setup}

experiment = List.first(System.argv()) || "base_77obj_dist_agent"

{:ok, opened} = Studio.open(experiment)
IO.puts("#{experiment}: #{length(Setup.objects(opened.setup))} objects in the memory")

mean = fn list -> Enum.sum(list) / length(list) / 1_000 end

# The world alone: the same interface and actions, with no module between steps.
{:ok, world_only} = Run.start(opened.setup, steps: 40)

world =
  Enum.map(1..3, fn step ->
    {us, _} = :timer.tc(fn -> Interface.step(world_only.interface, world_only.pending_actions) end)
    IO.puts("  world #{step}: #{Float.round(us / 1_000, 1)} ms")
    us
  end)

# Whole steps, on a run of their own, so neither measurement is warmed by the
# other.
{:ok, running} = Run.start(opened.setup, steps: 40)

{whole, _run} =
  Enum.map_reduce(1..3, running, fn step, run ->
    {us, {:ok, _info, _observations, run}} = :timer.tc(fn -> Run.step(run) end)
    IO.puts("  step #{step}: #{Float.round(us / 1_000, 1)} ms")
    {us, run}
  end)

IO.puts(
  "\nworld #{Float.round(mean.(world), 1)} ms/step, whole #{Float.round(mean.(whole), 1)} ms/step, " <>
    "modules #{Float.round(mean.(whole) - mean.(world), 1)} ms/step"
)
