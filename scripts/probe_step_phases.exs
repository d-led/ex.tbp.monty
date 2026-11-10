# Where a step's time goes, phase by phase and process by process.
#
#   MIX_ENV=test mix run scripts/probe_step_phases.exs [experiment] [steps]
#
# `probe_step_cost.exs` answers what a whole step costs; this one answers where
# it is, which is the question that decides what to optimise. Two splits:
#
#   * **world against model.** `Interface.step/2` is the environment — rendering,
#     the depth and point-cloud transforms, the proprioceptive state — and
#     `Model.step/4` is everything the model does with the result. They are
#     timed separately because a rendered step and a matched step are different
#     problems, and a whole-step figure mixes them.
#   * **process against process.** A step is not one process: the coordinator
#     routes, each sensor module and each learning module does part of it in its
#     own server. Reductions are counted per process, because they do not move
#     with the load on the machine and wall time does.
#
# `Monty.Runtime.Step` reports whether a step gave a module something to process.
# A step that did not is a location only — Monty's `motor_only_step`, three of
# every four — and it costs about a sixth of a processed one, so the two are
# printed separately: an average over both describes neither.
#
# CPU is the sum of scheduler-active microseconds
# (`:erlang.statistics(:scheduler_wall_time_all)`, which needs
# `:erlang.system_flag(:scheduler_wall_time, true)` first). It is quoted beside
# wall time so a step that is heavy can be told from a step that is starved.

alias Monty.Context
alias Monty.Experiment.Environment.Interface
alias Monty.Studio

Code.require_file("scripts/probe_support.exs", ".")

experiment = System.argv() |> List.first() || "base_10simobj_surf_agent"
steps = System.argv() |> Enum.at(1) |> then(&(&1 && String.to_integer(&1))) || 40

opened = ProbeSupport.setup(experiment)
{:ok, run} = Studio.Run.start(opened.setup, steps: steps * 10)
:ok = Studio.Run.set_ground_truth(run)

:erlang.system_flag(:scheduler_wall_time, true)

cpu_us = fn ->
  :erlang.statistics(:scheduler_wall_time_all)
  |> Enum.reduce(0, fn {_scheduler, active, _total}, sum -> sum + active end)
end

reductions = fn pid -> Process.info(pid, :reductions) |> elem(1) end

# The step's own processes, named the way the registry names them.
parties = fn model_id ->
  Elixir.Registry.select(Monty.Runtime.Registry.registry(), [
    {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
  ])
  |> Enum.flat_map(fn {key, pid, _value} ->
    case key do
      {:step, ^model_id} -> [{{:coordinator, model_id}, pid}]
      {kind, ^model_id, id} when kind in [:sensor_module, :learning_module] -> [{{kind, id}, pid}]
      _ -> []
    end
  end)
end

IO.puts("#{experiment}: #{steps} steps")

{processed, plain} =
  Enum.reduce(1..steps, {[], []}, fn _, {processed, plain} ->
    people = parties.(run.model_id)
    before = Map.new(people, fn {key, pid} -> {key, reductions.(pid)} end)

    {world_us, {observations, proprio, interface}} =
      :timer.tc(fn -> Interface.step(run.interface, run.pending_actions) end)

    cpu_before = cpu_us.()

    {model_us, {:ok, actions, info}} =
      :timer.tc(fn ->
        Monty.Runtime.Model.step(
          run.model_id,
          observations,
          proprio,
          %{Context.new(run.episode_seed) | step: run.step}
        )
      end)

    cpu = cpu_us.() - cpu_before

    work =
      people
      |> Enum.map(fn {key, pid} -> {key, reductions.(pid) - before[key]} end)
      |> Enum.reject(fn {_key, delta} -> delta == 0 end)
      |> Enum.sort_by(fn {_key, delta} -> -delta end)

    run = %{
      run
      | interface: interface,
        step: run.step + 1,
        pending_actions: actions
    }

    row = %{step: info.step, world_us: world_us, model_us: model_us, cpu_us: cpu, work: work}

    if info.processed?, do: {[row | processed], plain}, else: {processed, [row | plain]}
  end)

report = fn label, rows ->
  case rows do
    [] ->
      IO.puts("\n#{label}: none in this window")

    _ ->
      mean = fn field ->
        rows |> Enum.map(&Map.fetch!(&1, field)) |> Enum.sum() |> div(length(rows))
      end

      IO.puts(
        "\n#{label}: #{length(rows)} steps\n" <>
          "  mean wall: world #{div(mean.(:world_us), 1000)} ms, model #{div(mean.(:model_us), 1000)} ms\n" <>
          "  mean cpu:  #{div(mean.(:cpu_us), 1000)} ms"
      )

      rows
      |> Enum.flat_map(& &1.work)
      |> Enum.group_by(fn {key, _} -> elem(key, 0) end, fn {_, delta} -> delta end)
      |> Enum.map(fn {kind, deltas} -> {kind, div(Enum.sum(deltas), length(rows))} end)
      |> Enum.sort_by(fn {_kind, mean_delta} -> -mean_delta end)
      |> Enum.each(fn {kind, mean_delta} ->
        IO.puts("  #{mean_delta} reductions/step  #{kind}")
      end)
  end
end

report.("processed", Enum.reverse(processed))
report.("plain (location only)", Enum.reverse(plain))
