# Where a step's wall clock goes when eight cores are offered the work.
#
#   DB_PORT=5432 MIX_ENV=test mix run scripts/probe_step_busy.exs [experiment] [steps]
#
# The object round folds one object's update into a process and starts a few
# dozen of them a step, so the question "what is left in the round" is really
# "how much of the machine is a step using". `:msacc` answers it: it samples
# every scheduler and dirty scheduler and says what each was doing — `emulator`
# (running code), `gc`, `port`, `bif`, `other` — and how long it had nothing to
# do (`sleep`). Summed over the schedulers that is the machine's utilisation.
#
# The counters are microseconds. A step near the core count means the step is the
# machine's limit and no amount of spawning gets under it; a step well under it is
# waiting on something, and the *next* measurement is that something — not a
# worker pool.
#
# Measured on this Mac (stand-in world, `base_77obj_dist_agent`, hypotheses in
# the low thousands): a step of ~50 ms carries ~93 ms of ordinary-scheduler work
# and ~120 ms of dirty-CPU work over the eight cores — 4.4 of 8 cores busy, so
# the step is not machine-bound. The dirty work is one k-nearest query per
# hypothesis (`/usr/bin/sample` puts kiddo's `nearest_n_recurse` first by a wide
# margin) and the ordinary work is everything else, 4 % of it garbage collection.
#
# Not a gate: the milliseconds are this box's. Read the shape.

alias Monty.Studio
alias Monty.Studio.Run

defmodule StepBusy do
  @moduledoc "Utilisation of the schedulers a step was given, in one table."

  # What a scheduler was doing that is work it did itself. `other` is dropped:
  # it is uncounted time inside the emulator, not work a change can move.
  @work [:emulator, :gc, :port, :bif]

  @doc """
  The account, as `{{type, id}, %{state => us}}`.

  Accounting has to be switched on first; its own answer to being switched on is
  not a reading, so it is not matched.
  """
  def read do
    _ = :msacc.start()
    :msacc.stats() |> Map.new(fn row -> {{row.type, row.id}, row.counters} end)
  end

  @doc "What one step spent, state by state, scheduler by scheduler."
  def delta(before, after_step) do
    Map.new(after_step, fn {{type, id}, counters} ->
      was = Map.fetch!(before, {type, id})

      {{type, id},
       Map.new(counters, fn {state, value} -> {state, value - Map.fetch!(was, state)} end)}
    end)
  end

  @doc "The sum of several steps' accounts, so a reading is an average."
  def sum(arms), do: Enum.reduce(arms, %{}, &add(&2, &1))

  defp add(account, deltas) do
    Map.merge(account, deltas, fn _key, left, right ->
      Map.merge(left, right, fn _state, a, b -> a + b end)
    end)
  end

  @doc "One table, with the machine's total and what the step waited on."
  def report(account, steps, step_us) do
    rows = for {{:scheduler, id}, counters} <- account, do: {id, counters}

    IO.puts(
      "  #{steps} steps, #{Float.round(step_us / 1000, 1)} ms a step, " <>
        "#{length(rows)} schedulers"
    )

    IO.puts(
      "  #{String.pad_leading("id", 4)} #{String.pad_leading("running", 9)} " <>
        "#{String.pad_leading("gc", 8)} #{String.pad_leading("busy", 9)} " <>
        "#{String.pad_leading("idle", 9)}"
    )

    for {id, counters} <- rows do
      IO.puts(
        "  #{String.pad_leading("#{id}", 4)} #{String.pad_leading(per_step(counters, :emulator, steps), 9)} " <>
          "#{String.pad_leading(per_step(counters, :gc, steps), 8)} " <>
          "#{String.pad_leading(per_step(counters, :busy, steps), 9)} " <>
          "#{String.pad_leading(per_step(counters, :sleep, steps), 9)}"
      )
    end

    capacity = length(rows) * steps * step_us
    total = rows |> Enum.map(fn {_id, counters} -> busy(counters) end) |> Enum.sum()
    gc = rows |> Enum.map(fn {_id, counters} -> value(counters, :gc) end) |> Enum.sum()
    idle = rows |> Enum.map(fn {_id, counters} -> value(counters, :sleep) end) |> Enum.sum()

    IO.puts("")

    IO.puts(
      "  ordinary schedulers: #{ms(total, steps)}/step of work (#{share(total, capacity)} of the machine), " <>
        "#{ms(gc, steps)}/step of it GC, #{ms(idle, steps)}/step idle"
    )

    dirty = for {{:dirty_cpu_scheduler, _id}, counters} <- account, do: busy(counters)

    IO.puts(
      "  dirty cpu: #{ms(Enum.sum(dirty), steps)}/step of work " <>
        "(#{share(Enum.sum(dirty), capacity)} of the machine), one k-nearest search per hypothesis"
    )

    cores = (total + Enum.sum(dirty)) / (steps * step_us)
    IO.puts("  the step uses #{Float.round(cores, 1)} of #{length(rows)} cores")
  end

  defp value(counters, :busy), do: busy(counters)
  defp value(counters, state), do: Map.get(counters, state, 0)

  defp busy(counters), do: Enum.reduce(@work, 0, &(value(counters, &1) + &2))

  defp ms(us, steps), do: "#{Float.round(us / steps / 1000, 1)} ms"

  defp per_step(counters, state, steps),
    do: "#{Float.round(value(counters, state) / steps / 1000, 1)}"

  defp share(_part, 0), do: "—"
  defp share(part, whole), do: "#{Float.round(part / whole * 100, 0)} %"
end

experiment = List.first(System.argv()) || "base_77obj_dist_agent"
steps = System.argv() |> Enum.at(1, "3") |> String.to_integer()

{:ok, opened} = Studio.open(experiment)
{:ok, run} = Run.start(opened.setup, steps: 40)

# The first steps of a run grow every task's heap from nothing, so they are not
# the shape being measured: five warm steps first.
warm = 5

run =
  Enum.reduce(1..warm, run, fn _step, run ->
    {:ok, _info, _observations, run} = Run.step(run)
    run
  end)

arms =
  Enum.map(1..steps, fn _step ->
    before = StepBusy.read()
    {us, {:ok, _info, _observations, run}} = :timer.tc(fn -> Run.step(run) end)
    {us, StepBusy.delta(before, StepBusy.read()), run}
  end)

run = arms |> Enum.map(&elem(&1, 2)) |> List.last()
step_us = arms |> Enum.map(&elem(&1, 0)) |> Enum.sum() |> Kernel.div(steps)
account = arms |> Enum.map(&elem(&1, 1)) |> StepBusy.sum()

IO.puts("\n#{experiment}, #{steps} steps after #{warm} warm\n")
StepBusy.report(account, steps, step_us)

Run.stop(run)
