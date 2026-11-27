defmodule Monty.Frameworks.RunParallel do
  @moduledoc """
  Which episodes of a list a selection string asks for.

  Mirrors `tbp/monty/frameworks/run_parallel.py`. Monty's parallel runner takes
  `--episodes 0,3,5:8` and hands every worker the same rule, so the grammar is a
  contract, and the shape of the refusal matters as much as the answer: ranges
  are **validated, not clamped**. A selection that falls outside `[0, total)`
  stops the run instead of quietly running fewer episodes than were asked for,
  because an experiment whose episode list was silently shortened is a result
  nobody can reproduce.

  Monty raises `ValueError`; the port raises `ArgumentError`, and every refusal
  names the part of the selection that was refused.

  `per_lm_stats/1` and the WandB helpers in Monty's module are not here — see
  `docs/monty-differences.md` §2.52.
  """

  @open_left ~r/^:(\d+)$/
  @open_right ~r/^(\d+):$/
  @closed ~r/^(\d+)\s*:\s*(\d+)$/
  @single ~r/^\d+$/

  @doc """
  The zero-based episode indices a selection names, sorted and deduplicated.

  `nil`, `""`, `"all"` and `":"` are every index. Otherwise a comma-separated
  list of single indices (`"3"`), closed ranges (`"2:5"`, end exclusive) and open
  ranges (`":3"` for the first three, `"7:"` for the rest). Whitespace around a
  part, and around a range's colon, is ignored.

  A range that names nothing (`"3:3"`), runs backwards (`"5:3"`) or reaches past
  the list (`"0:6"` of five) is refused, as is an index that is not in it — only
  the select-all forms are allowed to be empty, because they are what a run with
  no episode list uses.
  """
  @spec parse_episode_spec(String.t() | nil, non_neg_integer()) :: [non_neg_integer()]
  def parse_episode_spec(nil, total), do: every(total)

  def parse_episode_spec(spec, total) do
    case spec |> String.trim() |> String.downcase() do
      all when all in ["", "all", ":"] ->
        every(total)

      selection ->
        selection
        |> String.split(",")
        |> Enum.reduce(MapSet.new(), &select(&1, &2, total))
        |> Enum.sort()
    end
  end

  @doc """
  The entries a selection names, in their own order.

  Monty's `filter_episode_configs`: the same grammar, applied to whatever the
  runner is choosing between.
  """
  @spec filter_episode_configs([entry], String.t() | nil) :: [entry] when entry: term()
  def filter_episode_configs(entries, episode_spec) do
    chosen = MapSet.new(parse_episode_spec(episode_spec, length(entries)))

    entries
    |> Enum.with_index()
    |> Enum.filter(fn {_entry, index} -> MapSet.member?(chosen, index) end)
    |> Enum.map(fn {entry, _index} -> entry end)
  end

  defp every(total), do: Enum.to_list(0..(total - 1)//1)

  # An empty part is a trailing or doubled comma, which Monty skips rather than
  # refuses.
  defp select(raw, chosen, total) do
    case String.trim(raw) do
      "" -> chosen
      part -> chosen |> MapSet.union(MapSet.new(indices(part, total)))
    end
  end

  # Monty tries the forms in this order: open-left, open-right, closed, single.
  # A part none of them match is a selection the runner cannot read.
  defp indices(part, total) do
    cond do
      match = Regex.run(@open_left, part) ->
        first_episodes(Enum.at(match, 1), part, total)

      match = Regex.run(@open_right, part) ->
        from_episode(Enum.at(match, 1), part, total)

      match = Regex.run(@closed, part) ->
        between(Enum.at(match, 1), Enum.at(match, 2), part, total)

      Regex.match?(@single, part) ->
        one(part, total)

      true ->
        raise ArgumentError, "#{part} is not a valid selection."
    end
  end

  # ":N" — the first N episodes, and N has to name at least one of them.
  defp first_episodes(last, part, total) do
    last = String.to_integer(last)

    if 0 < last and last <= total,
      do: Enum.to_list(0..(last - 1)//1),
      else: invalid_range(part)
  end

  # "N:" — from N to the end, and N has to be an episode there.
  defp from_episode(first, part, total) do
    first = String.to_integer(first)

    if 0 <= first and first < total,
      do: Enum.to_list(first..(total - 1)//1),
      else: invalid_range(part)
  end

  # "A:B" — a half-open range inside the list that names at least one episode.
  defp between(first, last, part, total) do
    first = String.to_integer(first)
    last = String.to_integer(last)

    if 0 <= first and first < last and last <= total,
      do: Enum.to_list(first..(last - 1)//1),
      else: invalid_range(part)
  end

  defp one(part, total) do
    index = String.to_integer(part)

    if 0 <= index and index < total,
      do: [index],
      else: raise(ArgumentError, "#{part} is not a valid index.")
  end

  defp invalid_range(part), do: raise(ArgumentError, "#{part} is not a valid range.")
end
