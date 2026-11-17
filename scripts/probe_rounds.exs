# Where a step's time goes inside the model, round by round.
#
#   MIX_ENV=test mix run scripts/probe_rounds.exs [experiment] [steps]
#
# `probe_step_phases.exs` splits a step into world and model; this one opens the
# model. `Monty.Runtime.Step` is a sequence of rounds — sensors, the learning
# modules' hand-off, their epoch wait, the vote round, the settle round, the goal
# and region reads — and a step's cost is one round after another inside one
# process. The question a parallel step has to answer before anything is
# rewritten is *which* round the coordinator spends its time in, and how much of
# a round is waiting for a module rather than working.
#
# `:fprof` traces the coordinator process only. Its own times are inflated by the
# tracer — the factor depends on how many calls a function makes — so compare the
# rounds with each other and read the call counts as the exact numbers they are
# (see `docs/speed.md`, "Measure like this"). A round whose own time is small and
# whose count is one per step is a round that is waiting, and eprof's own-time
# cannot tell it from a round that is cheap.
#
# The coordinator is the process the rounds run in; the modules do their work in
# their own, which `probe_step_phases.exs` already counts per process.
alias Monty.Context
alias Monty.Experiment.Environment.Interface
alias Monty.Studio

Code.require_file("scripts/probe_support.exs", ".")

experiment = System.argv() |> List.first() || "base_10simobj_surf_agent"
steps = System.argv() |> Enum.at(1) |> then(&(&1 && String.to_integer(&1))) || 6

opened = ProbeSupport.setup(experiment)
{:ok, run} = Studio.Run.start(opened.setup, steps: steps * 10)
:ok = Studio.Run.set_ground_truth(run)

coordinator =
  Elixir.Registry.select(Monty.Runtime.Registry.registry(), [
    {{{:step, run.model_id}, :"$1", :"$2"}, [], [:"$1"]}
  ])
  |> List.first()

IO.puts("#{experiment}: #{steps} steps, coordinator #{inspect(coordinator)}")

if coordinator == nil do
  IO.puts("no step coordinator is registered for #{inspect(run.model_id)}")
else
  # One step before tracing: the first step of an episode builds what later steps
  # reuse, and a trace of it would be a trace of a different shape of step.
  {_us, {observations, proprio, interface}} =
    :timer.tc(fn -> Interface.step(run.interface, run.pending_actions) end)

  {:ok, actions, _info} =
    Monty.Runtime.Model.step(
      run.model_id,
      observations,
      proprio,
      %{Context.new(run.episode_seed) | step: run.step}
    )

  run = %{run | interface: interface, step: run.step + 1, pending_actions: actions}

  :fprof.trace([:start, procs: [coordinator]])

  run =
    Enum.reduce(1..steps, run, fn _, run ->
      {_us, {observations, proprio, interface}} =
        :timer.tc(fn -> Interface.step(run.interface, run.pending_actions) end)

      {:ok, actions, _info} =
        Monty.Runtime.Model.step(
          run.model_id,
          observations,
          proprio,
          %{Context.new(run.episode_seed) | step: run.step}
        )

      %{run | interface: interface, step: run.step + 1, pending_actions: actions}
    end)

  :fprof.trace(:stop)
  :fprof.profile()

  destination = Path.join(System.tmp_dir!(), "fprof-rounds.txt")
  :fprof.analyse(dest: String.to_charlist(destination), totals: true, sort: :own)

  destination
  |> File.read!()
  |> String.split("\n")
  |> Enum.filter(&String.contains?(&1, "Monty.Runtime.Step"))
  |> Enum.reject(&String.contains?(&1, "step/4"))
  |> Enum.take(40)
  |> Enum.each(&IO.puts/1)

  IO.puts("\nfull profile: #{destination}")
end
