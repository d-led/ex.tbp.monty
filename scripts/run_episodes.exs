# What a recorded run did, episode by episode.
#
#   MIX_ENV=test mix run --no-start scripts/run_episodes.exs <run-id> [<run-id> ...]
#
# A run's transcript is per step and carries the episode it belongs to, so this
# groups it and prints one line an episode: what it concluded, how many steps of
# the experiment it took, and how many of those reached the learning module. Two
# worlds of the same experiment can be compared on that, which is what a "did the
# world change the outcome" question needs.

alias Monty.Studio.RunHistory

for id <- System.argv() do
  record = RunHistory.head(id)
  entries = Enum.filter(record.log, &is_map/1)

  episodes =
    entries
    |> Enum.group_by(& &1["episode"])
    |> Enum.sort_by(fn {episode, _entries} -> episode || -1 end)

  IO.puts("=== run #{id} (#{record.status}, #{length(entries)} steps, #{length(episodes)} episodes)")

  for {episode, entries} <- episodes do
    steps = length(entries)

    last = List.last(entries)
    graphs = get_in(last, ["beliefs"]) || %{}

    best =
      graphs
      |> Enum.map(fn {module, belief} ->
        possible = get_in(belief, ["graphs"]) || %{}

        {module,
         possible
         |> Enum.map(fn {name, graph} -> {name, graph["max_evidence"] || 0.0} end)
         |> Enum.max_by(&elem(&1, 1), fn -> {"none", 0.0} end)}
      end)

    conclusions =
      graphs
      |> Enum.map(fn {module, belief} ->
        "#{module}: #{inspect(get_in(belief, ["terminal_state"]))}"
      end)
      |> Enum.join(" · ")

    IO.puts(
      "  ep #{episode} · #{steps} steps · best #{inspect(best)} · #{conclusions}"
    )
  end
end
