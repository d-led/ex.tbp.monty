# What one step of a 77-object episode costs, step by step.
#
#   MIX_ENV=test mix run --no-start scripts/measure_step_memory.exs [experiment] [steps]
#
# `base_77obj_dist_agent` is killed inside its first episode by the studio's
# per-process heap ceiling, while its library is 213 MB of heap and the module
# that holds it copies nothing. So the six gigabytes appear during a step, and
# this watches the model's own process as it takes them: its heap before the
# first step, after each one, and what the run itself holds.
#
# The ceiling here is this script's own (3 GB, below the studio's 4 GB) so a
# runaway is stopped before it reaches the machine's swap rather than after.

alias Monty.Studio.{Run, Setup}

experiment = Enum.at(System.argv(), 0) || "base_77obj_dist_agent"
steps = (Enum.at(System.argv(), 1) || "6") |> String.to_integer()

:erlang.system_flag(:max_heap_size, %{
  size: div(3 * 1024 * 1024 * 1024, :erlang.system_info(:wordsize)),
  kill: true,
  error_logger: true
})

megabytes = fn bytes -> Float.round(bytes / 1.0e6, 1) end

{:ok, setup} = Setup.from_experiment(experiment)
run = Run.start(setup)

pid =
  case Registry.lookup(Monty.Runtime.Registry, {:step, run.model_id}) do
    [{pid, _value}] -> pid
    [] -> nil
  end

held = fn ->
  case pid && Process.alive?(pid) do
    true -> megabytes.(:erlang.process_info(pid, :memory) |> elem(1))
    false -> :dead
  end
end

IO.puts("""
#{experiment}: #{steps} steps, watched

  the step process before step 1: #{held.()} MB
  the VM:                         #{megabytes.(:erlang.memory(:total))} MB
""")

Enum.reduce_while(1..steps, run, fn index, run ->
  {microseconds, result} = :timer.tc(fn -> Run.step(run) end)

  case result do
    {:ok, info, _observations, run} ->
      hypotheses =
        Map.get(info, :learning_module_0, %{}) |> inspect(limit: 2, printable_limit: 80)

      IO.puts(
        "  step #{index}: #{div(microseconds, 1000)} ms, process #{held.()} MB, " <>
          "VM #{megabytes.(:erlang.memory(:total))} MB, #{hypotheses}"
      )

      {:cont, run}

    other ->
      IO.puts("  step #{index} answered #{inspect(other, limit: 3)}")
      {:halt, run}
  end
end)

Run.stop(run)
