# A sampling profile of one 77-object step: every few milliseconds the stack of
# every process is read and the frames counted. Instrumenting 400 million calls
# answers "how often", not "how long"; sampling answers where the time is.
#
#   MONTY_MODELS=… mix run scripts/sample_step.exs

alias Monty.Studio
alias Monty.Studio.{Run, Setup}

{:ok, opened} = Studio.open("base_77obj_dist_agent")
{:ok, run} = Run.start(opened.setup, steps: 40)
IO.puts("#{length(Setup.objects(opened.setup))} objects in the memory")

{:ok, _info, _observations, run} = Run.step(run)

defmodule Sampler do
  @doc "Runs `fun`, sampling every `interval` milliseconds, and counts frames."

  def run(fun, interval \\ 4) do
    parent = self()

    sampler =
      spawn_link(fn -> send(parent, {:samples, collect(%{}, interval)}) end)

    {us, value} = :timer.tc(fun)
    send(sampler, :stop)

    receive do
      {:samples, counts} -> {us, value, counts}
    after
      5_000 -> {us, value, %{}}
    end
  end

  defp collect(counts, interval) do
    receive do
      :stop -> counts
    after
      interval -> collect(tally(counts), interval)
    end
  end

  defp tally(counts) do
    Process.list()
    |> Enum.filter(&working?/1)
    |> Enum.flat_map(fn pid ->
      case :erlang.process_info(pid, :current_stacktrace) do
        {:current_stacktrace, frames} -> Enum.take(frames, 4)
        _gone -> []
      end
    end)
    |> Enum.reduce(counts, fn {module, function, arity, _info}, counts ->
      Map.update(counts, "#{inspect(module)}.#{function}/#{arity}", 1, &(&1 + 1))
    end)
  end

  # A process waiting for its next message is not spending the step's time; one
  # that is running or about to run is.
  defp working?(pid) do
    case :erlang.process_info(pid, :status) do
      {:status, status} -> status in [:running, :runnable]
      _gone -> false
    end
  end
end

{us, _value, counts} = Sampler.run(fn -> Run.step(run) end)

IO.puts("step: #{Float.round(us / 1_000, 1)} ms")

counts
|> Enum.sort_by(fn {_frame, count} -> -count end)
|> Enum.take(30)
|> Enum.each(fn {frame, count} ->
  IO.puts("  #{String.pad_leading(to_string(count), 6)}  #{frame}")
end)
