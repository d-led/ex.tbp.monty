# Two `mix monty.run` logs, episode by episode.
#
#   MIX_ENV=test mix run --no-start scripts/compare_runs.exs a.log b.log
#
# The CLI prints an episode's steps as `step i · …` lines between `episode N/M`
# and the line that says what the learning module concluded, so a log is read the
# way a person reads it. What this answers is the question two worlds are compared
# for: did they reach the same conclusion, and at what cost in steps.
#
# A world is a version of MuJoCo and a way of drawing pictures, so two of them
# agree on conclusions and not on step counts: a step or two per episode is
# shading, and hundreds is one of them reaching its step budget. The run's own
# summary line — "N steps: X µs in the model, Y µs in the world" — is printed
# beside the count taken from the log, because a log that lost lines still knows
# how far it got.

defmodule Runs do
  @episode ~r/^episode (\d+)\/(\d+)$/
  @step ~r/^\S+ step (\d+) · percepts/
  @conclusion ~r/^learning_module_0: (match|time_out|no_match)\b/
  @summary ~r/^(\d+) steps: (\d+) µs in the model, (\d+) µs in the world/

  def read(path) do
    {episodes, open, summary} =
      path
      |> File.stream!(:line)
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reduce({[], nil, nil}, fn line, {done, open, summary} ->
        collect(line, done, open, summary)
      end)

    %{episodes: Enum.reverse(close(episodes, open)), summary: summary}
  end

  defp collect(line, done, open, summary) do
    cond do
      match = Regex.run(@episode, line) ->
        [_, number, total] = match
        {close(done, open), %{number: number, total: total, steps: 0, conclusion: nil}, summary}

      open == nil ->
        {done, open, summary}

      match = Regex.run(@conclusion, line) ->
        [_, conclusion] = match
        {done, %{open | conclusion: conclusion}, summary}

      match = Regex.run(@step, line) ->
        [_, index] = match
        {done, %{open | steps: String.to_integer(index) + 1}, summary}

      match = Regex.run(@summary, line) ->
        [_, steps, model, world] = match
        {done, open, %{steps: steps, model_us: model, world_us: world}}

      true ->
        {done, open, summary}
    end
  end

  defp close(done, nil), do: done
  defp close(done, open), do: [open | done]

  def counts(%{episodes: episodes}) do
    %{
      episodes: length(episodes),
      steps: Enum.sum(Enum.map(episodes, & &1.steps)),
      match: Enum.count(episodes, &(&1.conclusion == "match")),
      time_out: Enum.count(episodes, &(&1.conclusion == "time_out"))
    }
  end
end

[left, right] = System.argv()

if left == nil or right == nil do
  IO.puts("usage: mix run --no-start scripts/compare_runs.exs <a.log> <b.log>")
  exit(64)
end

[a, b] = Enum.map([left, right], &Runs.read/1)

for {path, run} <- [{left, a}, {right, b}] do
  counts = Runs.counts(run)

  said =
    case run.summary do
      nil ->
        ""

      %{steps: steps, model_us: model, world_us: world} ->
        " — its own count: #{steps} steps, #{div(String.to_integer(model), 1000)} ms in the model, " <>
          "#{div(String.to_integer(world), 1000)} ms in the world"
    end

  IO.puts(
    "#{path}: #{counts.episodes} episodes, #{counts.steps} steps, " <>
      "#{counts.match} match, #{counts.time_out} time_out#{said}"
  )
end

pairs = Enum.zip(a.episodes, b.episodes)

differences =
  for {%{number: number, steps: x, conclusion: first}, %{steps: y, conclusion: second}} <- pairs,
      first != second,
      do:
        "episode #{number}: #{first || "no conclusion"} in #{x} steps, #{second || "none"} in #{y}"

IO.puts("")
IO.puts("#{length(pairs) - length(differences)} of #{length(pairs)} episodes agree")
for difference <- differences, do: IO.puts("  " <> difference)

deltas = for {%{steps: x}, %{steps: y}} <- pairs, do: y - x

if deltas != [] do
  mean = Enum.sum(deltas) / length(deltas)

  IO.puts(
    "steps b - a: total #{Enum.sum(deltas)}, mean #{Float.round(mean, 1)}, " <>
      "max #{Enum.max(deltas)}, min #{Enum.min(deltas)}"
  )
end
