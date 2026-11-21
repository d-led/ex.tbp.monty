# What one episode costs the machine, which is how `max_concurrency` is chosen.
#
#   MIX_ENV=test mix run scripts/probe_episode_peak.exs [experiment] [steps]
#
# `docs/parallel-and-live.md` §3 says the right number of parts is
# `min(schedulers, budget / episode_peak)`, and that the peak has to be measured:
# the library is shared (it is immutable data handed to every module), the
# hypothesis space is not — an episode holds hypotheses over every object it is
# matching, and a second episode holds a second set.
#
# Three readings, because the difference between them is the answer:
#
#   * the app up, before any run — what the node costs on its own;
#   * one run started — what a run's own start costs, the shared library included;
#   * the peak while it steps — the most one episode ever added.
#
# The second run's addition is the third reading minus the library's share, so a
# budget divided by it is per-episode arithmetic rather than a guess. Quote which
# box, which world and which experiment a reading came from.
defmodule ProbeEpisodePeak do
  alias Monty.Studio

  @default_experiment "base_config_10distinctobj_dist_agent"
  # Past this the reading is of a run, not of an episode; a recognition episode of
  # the configs here ends far inside it.
  @default_steps 300

  def main(argv) do
    experiment = Enum.at(argv, 0, @default_experiment)
    steps = argv |> Enum.at(1) |> parse_steps()

    {:ok, opened} = Studio.open(experiment)
    IO.puts("#{experiment} · #{opened.setup.world} · up to #{steps} steps")

    base = :erlang.memory(:total)
    say("the app up:", base)

    {:ok, run} =
      Studio.Run.start(Studio.Setup.with_phase(opened.setup, :eval),
        steps: steps,
        episode: 0,
        epoch: 0,
        mode: :eval,
        first_seen: %{}
      )

    started = :erlang.memory(:total)
    say("one episode started (its library read):", started)

    {peak, taken} = step(run, max(base, started), 0)
    say("peak while stepping:", peak)
    IO.puts("steps taken: #{taken}")
    say("the episode's own start above the app:", started - base)
    say("the peak above the episode's start:", peak - started)
    say("the peak above the app:", peak - base)
  end

  defp step(run, peak, taken) do
    case Studio.Run.step(run) do
      {:ok, _info, _observations, next} ->
        peak = max(peak, :erlang.memory(:total))
        taken = taken + 1

        if Studio.Run.finished?(next), do: {peak, taken}, else: step(next, peak, taken)

      {:error, reason} ->
        IO.puts("the run stopped after #{taken} steps: #{inspect(reason)}")
        {peak, taken}
    end
  end

  defp parse_steps(nil), do: @default_steps

  defp parse_steps(text) do
    case Integer.parse(text) do
      {steps, ""} when steps > 0 -> steps
      _not_a_count -> raise ArgumentError, "steps is a positive integer, got: #{inspect(text)}"
    end
  end

  defp say(label, bytes), do: IO.puts("#{label} #{Float.round(bytes / 1_048_576, 1)} MB")
end

ProbeEpisodePeak.main(System.argv())
