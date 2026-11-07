# What copying a step's observations costs, in lists and in binaries.
#
#   MIX_ENV=test mix run scripts/probe_copy_cost.exs
#
# The allocation profile of a step puts 71.5% of its words under
# `gen_server:loop/5`. That reads like "the messages are the cost", and the
# obvious conclusion is to carry the camera arrays as flat binaries. This
# measures the difference first, because the answer decides whether a rewrite of
# the worlds, the depth transform and the sensor modules is worth doing.
#
# Measured 2026-11-07, ten objects: 369 439 words and 1 582 us a step as nested
# lists, 325 words and 1 us as flat binaries — a binary over 64 bytes is
# reference-counted and shared, not copied. Against a step of ~275 ms that is
# under 1%, so the rewrite was not done; and the word column of tprof is not the
# size of the messages, which is the trap this instrument exists to expose.

alias Monty.Studio

Code.require_file("probe_support.exs", __DIR__)

opened = ProbeSupport.setup("base_config_10distinctobj_dist_agent")
{:ok, run} = Studio.Run.start(opened.setup, steps: 2)
:ok = Studio.Run.set_ground_truth(run)
{:ok, _info, observations, _run} = Studio.Run.step(run)

defmodule ProbeCopyCost do
  @arrays ["rgba", "depth", "semantic", "semantic_3d", "sensor_frame_data"]

  @doc "The observation with every leaf array packed into one binary of float64."
  def packed(observations) do
    Map.new(observations, fn {agent, seen} ->
      {agent, Map.new(seen, fn {sensor, observation} -> {sensor, pack_arrays(observation)} end)}
    end)
  end

  defp pack_arrays(observation) do
    Map.new(observation, fn
      {key, value} when key in @arrays -> {key, pack(value)}
      other -> other
    end)
  end

  defp pack(term) when is_list(term) do
    term
    |> flatten([])
    |> Enum.map(fn value -> <<value * 1.0::float-64>> end)
    |> IO.iodata_to_binary()
  end

  defp pack(other), do: other

  defp flatten([], acc), do: Enum.reverse(acc)
  defp flatten([first | rest], acc) when is_list(first), do: flatten(rest, flatten(first, acc))
  defp flatten([first | rest], acc), do: flatten(rest, [first | acc])

  @doc "How long it takes to hand a term to a process that never reads it."
  def copy_cost(term, times \\ 20) do
    sink = spawn(fn -> receive_forever() end)
    {micros, _} = :timer.tc(fn -> for _ <- 1..times, do: send(sink, term) end)
    Process.exit(sink, :kill)
    div(micros, times)
  end

  defp receive_forever do
    receive do
      _anything -> receive_forever()
    end
  end
end

binaries = ProbeCopyCost.packed(observations)

IO.puts("observations as lists:    #{:erts_debug.size(observations)} words")
IO.puts("observations as binaries: #{:erts_debug.size(binaries)} words")
IO.puts("copy as lists:    #{ProbeCopyCost.copy_cost(observations)} us")
IO.puts("copy as binaries: #{ProbeCopyCost.copy_cost(binaries)} us")
