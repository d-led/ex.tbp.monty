defmodule Monty.Studio.EvalStats do
  @moduledoc """
  A run's `eval_stats.csv` read as what the run did, so that two runs can be put
  side by side.

  The columns are Monty's: `primary_performance` is what the learning module
  concluded about the object it was asked for, `TFNP` whether the target was
  among the possible matches, and the step and time columns what the episode
  cost. Monty writes them and so does this port, which is what makes a
  comparison worth making.

  Two runs are joined on `episode_seed`, which the two runs derive from the
  experiment's own config and therefore share, and are compared episode by
  episode where they share one. Where they do not — a run of twenty episodes
  against a run of a hundred and forty — the report describes each run's
  distributions instead, so a short run is still readable against a long one
  rather than being an error.

  A path may be a file, a run's folder, or a divided run's folder. A divided run
  reports each part into its own directory while the parts run and merges them
  when they are done, so the merged file is taken when it holds every part's
  episodes, and the parts themselves while the run is still going.
  """

  @typedoc "One episode's row, as the file wrote it."
  @type row :: %{optional(String.t()) => String.t()}

  @typedoc """
  A run read from disk.

  `by_seed` is the rows a comparison joins on, keyed by `episode_seed`; `files`
  is what the run was read from, which is more than one only for a divided run
  still in flight.
  """
  @type t :: %{
          name: String.t(),
          path: Path.t(),
          files: [Path.t()],
          rows: [row()],
          by_seed: %{optional(integer()) => row()},
          seeded?: boolean(),
          duplicates: non_neg_integer()
        }

  @typedoc "What an episode's numbers say about that episode."
  @type stats :: %{n: pos_integer(), mean: float(), median: float(), p90: float(), max: float()}

  # What a reader wants to know from an outcome, whichever run wrote it. The
  # port once wrote `match` for a module that recognised its target without
  # judging it; an older file is still readable, and says so rather than being
  # counted as correct.
  @judgements %{
    "correct" => "recognised",
    "correct_mlh" => "recognised",
    "confused" => "confused",
    "confused_mlh" => "confused",
    "pose_time_out" => "matched_pose_unfound",
    "no_match" => "unrecognised",
    "time_out" => "unrecognised",
    "patch_off_object" => "left_object",
    "no_label" => "unlabelled",
    "match" => "matched_unjudged"
  }

  # Why an episode ended: the recognition policy's own answer, read off the same
  # column, because the policy is what ends an episode.
  @exits %{
    "correct" => "matched",
    "correct_mlh" => "matched",
    "confused" => "matched",
    "confused_mlh" => "matched",
    "match" => "matched",
    "pose_time_out" => "pose_not_converged",
    "no_match" => "steps_exhausted",
    "time_out" => "steps_exhausted",
    "patch_off_object" => "no_surface",
    "no_label" => "no_label"
  }

  @targets %{
    "target_in_possible_matches_(TP)" => "target_found",
    "target_not_matched_(FN)" => "target_missed",
    "unknown_object_in_possible_matches_(FP)" => "unknown_object"
  }

  # The columns a report reads, and what each one is called in it.
  @metrics [
    {"num_steps", "sensor steps"},
    {"monty_steps", "steps over all modules"},
    {"monty_matching_steps", "matching steps"},
    {"time", "seconds"},
    {"num_possible_matches", "possible matches"},
    {"symmetry_evidence", "symmetry evidence"}
  ]

  @derived [{"pose error (m)", :pose_error}, {"rotation error (deg)", "rotation_error"}]

  @doc """
  Reads a run from a file, from a run's folder, or from the folders of its parts.

  A divided run keeps each part's record and folder of its own, so a part is
  named as a path like any other run and several parts are one run here: their
  episodes are read in the order given, and an episode reported twice is the
  last one's.

  The name is the folder's, shortened to fit a table column, unless the caller
  says what to call it.
  """
  @spec read(Path.t() | [Path.t()], String.t() | nil) :: t()
  def read(paths, name \\ nil)

  def read(path, name) when is_binary(path), do: read([path], name)

  def read([first | _rest] = paths, name) do
    {files, rows} =
      Enum.reduce(paths, {[], []}, fn path, {files, rows} ->
        {its_files, its_rows} = rows_of(Path.expand(path))
        {files ++ its_files, rows ++ its_rows}
      end)

    seeded? = rows != [] and Enum.all?(rows, &seeded?/1)
    {by_seed, duplicates} = index(rows, seeded?)

    %{
      name: name || short_name(first),
      path: Path.expand(first),
      files: files,
      rows: rows,
      by_seed: by_seed,
      seeded?: seeded?,
      duplicates: duplicates
    }
  end

  @doc "How many episodes the run reported."
  @spec episodes(t()) :: non_neg_integer()
  def episodes(%{rows: rows}), do: length(rows)

  @doc "What each episode concluded, counted by judgement."
  @spec outcomes(t()) :: %{optional(String.t()) => pos_integer()}
  def outcomes(%{rows: rows}), do: tally(rows, &judgement/1)

  @doc "Why each episode ended, counted by reason."
  @spec exits(t()) :: %{optional(String.t()) => pos_integer()}
  def exits(%{rows: rows}), do: tally(rows, &exit_of/1)

  @doc "Whether the target was among the possible matches, counted."
  @spec targets(t()) :: %{optional(String.t()) => pos_integer()}
  def targets(%{rows: rows}), do: tally(rows, &target_of/1)

  @doc "One column's mean, median, 90th percentile and largest value, or `nil`."
  @spec metric(t(), String.t() | :pose_error) :: stats() | nil
  def metric(%{rows: rows}, column) do
    values = rows |> Enum.map(&value(&1, column)) |> Enum.reject(&is_nil/1)
    describe(values)
  end

  @doc """
  Every column a report shows, in order, with the numbers it was read from.

  `pose error` is how far the recognised pose was from the object's, in metres,
  and `rotation error` is what the episode itself measured in degrees.
  """
  @spec metrics(t()) :: [{String.t(), stats() | nil}]
  def metrics(%{} = run) do
    Enum.map(@metrics, fn {column, label} -> {label, metric(run, column)} end) ++
      Enum.map(@derived, fn {label, column} -> {label, metric(run, column)} end)
  end

  @doc """
  Two runs side by side on the episodes they share.

  `disagreed` is the episodes whose judgement differs, in seed order, which is
  what a person reads to see whether a difference is one object or a habit.
  `deltas` is per column how far the base run's numbers sit from the other's,
  and how often the base run took fewer steps, more, or the same.
  """
  @spec compare(t(), t()) :: map()
  def compare(base, other) do
    shared = shared_seeds(base, other)

    %{
      shared: shared,
      only_here:
        Map.keys(base.by_seed) |> Enum.reject(&Map.has_key?(other.by_seed, &1)) |> Enum.sort(),
      only_there:
        Map.keys(other.by_seed) |> Enum.reject(&Map.has_key?(base.by_seed, &1)) |> Enum.sort(),
      agreed: Enum.count(shared, &(judgement(at(base, &1)) == judgement(at(other, &1)))),
      found_agreed: Enum.count(shared, &(target_of(at(base, &1)) == target_of(at(other, &1)))),
      disagreed: Enum.reject(shared, &(judgement(at(base, &1)) == judgement(at(other, &1)))),
      deltas: deltas(base, other, shared)
    }
  end

  @doc """
  The report a reader gets from one or more runs.

  Each run is profiled — outcomes, exits, targets, and the cost of an episode —
  and every run after the first is compared with the first.
  """
  @spec report([t()], keyword()) :: String.t()
  def report(runs, options \\ [])

  def report([%{} = run | _rest] = runs, options) do
    listed = Keyword.get(options, :disagreements, 20)

    [
      coverage(runs),
      for(run <- runs, do: profile(run)),
      distributions(runs),
      for(other <- tl(runs), do: comparison(run, other, listed))
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Whether a row names the episode it was reported for."
  @spec seeded?(row()) :: boolean()
  def seeded?(row) do
    case String.trim(Map.get(row, "episode_seed", "")) do
      "" -> false
      seed -> match?({_, ""}, Integer.parse(seed))
    end
  end

  @doc "What an episode's outcome says about the run, in one word."
  @spec judgement(row()) :: String.t()
  def judgement(row), do: word(row, "primary_performance", @judgements)

  @doc "Why the episode ended."
  @spec exit_of(row()) :: String.t()
  def exit_of(row), do: word(row, "primary_performance", @exits)

  @doc "Whether the target was among the possible matches."
  @spec target_of(row()) :: String.t()
  def target_of(row), do: word(row, "TFNP", @targets)

  defp word(row, column, table) do
    case row |> Map.get(column, "") |> String.trim() do
      "" -> "unrecorded"
      raw -> Map.get(table, raw, "other:" <> raw)
    end
  end

  # -- reading --------------------------------------------------------------

  # A divided run reports each part into its own directory while the parts run
  # and merges them when they are done, so a folder may hold both. The merged
  # file wins when it holds every part's episodes — reading both would count
  # each episode twice — and the parts are read when it does not, which is what
  # a run still in flight has.
  #
  # The path is the one an operator typed at a console, not one a request
  # chose: reading it is what `mix monty.compare` is for.
  # sobelow_skip ["Traversal.FileModule"]
  defp rows_of(path) do
    if File.dir?(path) do
      merged = Path.join(path, "eval_stats.csv")
      parts = path |> Path.join("parts/*/eval_stats.csv") |> Path.wildcard() |> Enum.sort()
      rows_of_folder(merged, parts)
    else
      {[path], rows_of_csv(File.read!(path))}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rows_of_folder(merged, []) do
    if File.exists?(merged), do: {[merged], rows_of_csv(File.read!(merged))}, else: {[], []}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rows_of_folder(merged, parts) do
    part_rows = Enum.flat_map(parts, &rows_of_csv(File.read!(&1)))

    case File.exists?(merged) do
      false ->
        {parts, part_rows}

      true ->
        merged_rows = rows_of_csv(File.read!(merged))

        if seeds(part_rows) |> MapSet.subset?(seeds(merged_rows)),
          do: {[merged], merged_rows},
          else: {parts, part_rows}
    end
  end

  defp seeds(rows) do
    rows |> Enum.map(&String.trim(Map.get(&1, "episode_seed", ""))) |> MapSet.new()
  end

  defp index(rows, true) do
    rows
    |> Enum.reduce({%{}, 0}, fn row, {by_seed, duplicates} ->
      {seed, ""} = Integer.parse(String.trim(Map.get(row, "episode_seed")))

      {Map.put(by_seed, seed, row),
       if(Map.has_key?(by_seed, seed), do: duplicates + 1, else: duplicates)}
    end)
  end

  defp index(rows, false),
    do: {rows |> Enum.with_index() |> Map.new(fn {row, index} -> {index, row} end), 0}

  @doc """
  The rows of a CSV as Monty and this port write it.

  A field may be quoted, and a quoted field may hold commas, newlines and
  doubled quotes — `possible_match_sources` is a Python list, so it holds the
  first two.
  """
  @spec rows_of_csv(String.t()) :: [row()]
  def rows_of_csv(text) do
    case parse(text) do
      [] ->
        []

      [columns | rows] ->
        Enum.map(rows, fn row ->
          columns
          |> Enum.zip(row ++ List.duplicate("", max(length(columns) - length(row), 0)))
          |> Map.new()
        end)
    end
  end

  defp parse(text) do
    text
    |> String.replace("\r\n", "\n")
    |> scan([], [], "", false)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == [""]))
  end

  defp scan(<<>>, records, fields, field, _quoted), do: [[field | fields] | records]

  defp scan("\"\"" <> rest, records, fields, field, true),
    do: scan(rest, records, fields, field <> "\"", true)

  defp scan("\"" <> rest, records, fields, field, true),
    do: scan(rest, records, fields, field, false)

  defp scan("\"" <> rest, records, fields, field, false),
    do: scan(rest, records, fields, field, true)

  defp scan("," <> rest, records, fields, field, false),
    do: scan(rest, records, [field | fields], "", false)

  defp scan("\n" <> rest, records, fields, field, false),
    do: scan(rest, [[field | fields] | records], [], "", false)

  defp scan(<<byte::utf8, rest::binary>>, records, fields, field, quoted),
    do: scan(rest, records, fields, field <> <<byte::utf8>>, quoted)

  # -- numbers --------------------------------------------------------------

  defp value(row, :pose_error), do: pose_error(row)
  defp value(row, column) when is_binary(column), do: number(row, column)

  defp number(row, column), do: row |> Map.get(column, "") |> parse_number()

  # Monty's numpy formatting writes a whole number as `0.`, which `Float.parse/1`
  # will not read.
  defp parse_number(text) do
    trimmed = String.trim(text)
    padded = if String.ends_with?(trimmed, "."), do: trimmed <> "0", else: trimmed

    case Float.parse(padded) do
      {value, ""} -> value
      _not_a_number -> nil
    end
  end

  # A vector as the file writes it: `[0.1 0.2 0.3]`, Monty's numpy formatting.
  defp vector(row, column) do
    parts =
      row
      |> Map.get(column, "")
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.split(~r/[\s,]+/, trim: true)

    parsed = Enum.map(parts, &parse_number/1)

    if parts != [] and Enum.all?(parsed, &(not is_nil(&1))), do: parsed
  end

  defp pose_error(row) do
    with [_, _ | _] = found <- vector(row, "detected_location"),
         [_, _ | _] = placed when length(placed) == length(found) <-
           vector(row, "primary_target_position") do
      :math.sqrt(
        Enum.zip_with(found, placed, fn left, right -> (left - right) ** 2 end)
        |> Enum.sum()
      )
    else
      _absent -> nil
    end
  end

  defp describe([]), do: nil

  defp describe(values) do
    ordered = Enum.sort(values)
    count = length(ordered)

    %{
      n: count,
      mean: Enum.sum(ordered) / count,
      median: median(ordered),
      p90: Enum.at(ordered, p90_index(count)),
      max: List.last(ordered)
    }
  end

  defp median(ordered) do
    count = length(ordered)

    case rem(count, 2) do
      0 -> (Enum.at(ordered, div(count, 2) - 1) + Enum.at(ordered, div(count, 2))) / 2
      1 -> Enum.at(ordered, div(count, 2))
    end
  end

  # The value below which nine tenths of the episodes lie, by nearest rank.
  defp p90_index(count), do: min(count - 1, round(0.9 * (count - 1)))

  defp tally(rows, classifier) do
    rows
    |> Enum.map(classifier)
    |> Enum.frequencies()
  end

  # -- the comparison -------------------------------------------------------

  defp shared_seeds(base, other) do
    base.by_seed
    |> Map.keys()
    |> Enum.filter(&Map.has_key?(other.by_seed, &1))
    |> Enum.sort()
  end

  defp row(run, seed), do: Map.fetch!(run.by_seed, seed)

  defp at(run, seed), do: Map.fetch!(run.by_seed, seed)

  defp deltas(base, other, shared) do
    for {column, _label} <- @metrics,
        differences = differences(base, other, shared, column),
        differences != [],
        into: %{} do
      {column,
       %{
         mean: Enum.sum(differences) / length(differences),
         median: median(Enum.sort(differences)),
         lower: Enum.count(differences, &(&1 < 0)),
         higher: Enum.count(differences, &(&1 > 0)),
         equal: Enum.count(differences, &(&1 == 0))
       }}
    end
  end

  defp differences(base, other, shared, column) do
    shared
    |> Enum.map(fn seed ->
      {number(row(base, seed), column), number(row(other, seed), column)}
    end)
    |> Enum.reject(fn {here, there} -> is_nil(here) or is_nil(there) end)
    |> Enum.map(fn {here, there} -> here - there end)
  end

  # -- the report -----------------------------------------------------------

  defp coverage(runs) do
    rows =
      Enum.map(runs, fn run ->
        [
          run.name,
          Integer.to_string(episodes(run)),
          Integer.to_string(map_size(run.by_seed)),
          Integer.to_string(length(run.files)),
          Integer.to_string(run.duplicates),
          if(run.seeded?, do: "yes", else: "no")
        ]
      end)

    [
      "\ncoverage\n",
      table(["run", "rows", "episodes", "files", "repeated seeds", "joined on seed"], rows),
      divided_note(runs)
    ]
  end

  defp divided_note(runs) do
    if Enum.any?(runs, &(length(&1.files) > 1)) do
      "\n" <>
        "a run read from more than one file is a divided run: its parts stepped at the\n" <>
        "same time, so its `seconds` column is what a part waited on this machine and not\n" <>
        "what the experiment costs alone. Step counts are unaffected.\n"
    else
      []
    end
  end

  defp profile(run) do
    rows = Enum.map(metrics(run), fn {label, stats} -> [label | describe_stats(stats)] end)

    [
      "\n",
      run.name,
      ": ",
      run.path,
      "\n",
      "  episodes  ",
      Integer.to_string(episodes(run)),
      "\n\n"
    ] ++
      ["per-episode metrics (mean / median / p90 / max)\n", table(["metric", run.name], rows)]
  end

  defp describe_stats(nil), do: ["-", "-", "-", "-"]

  defp describe_stats(stats),
    do: Enum.map([stats.mean, stats.median, stats.p90, stats.max], &short(&1))

  defp distributions(runs) do
    [
      distribution("outcome", runs, &outcomes/1),
      distribution("exit", runs, &exits/1),
      distribution("target found (TFNP)", runs, &targets/1)
    ]
  end

  defp distribution(title, runs, counter) do
    counted = Enum.map(runs, fn run -> {run.name, counter.(run), episodes(run)} end)

    labels =
      counted
      |> Enum.flat_map(fn {_name, counts, _total} -> Map.keys(counts) end)
      |> Enum.uniq()
      |> Enum.sort()

    rows =
      Enum.map(labels, fn label ->
        [
          label
          | Enum.map(counted, fn {_name, counts, total} ->
              share(Map.get(counts, label, 0), total)
            end)
        ]
      end)

    ["\n", title, "\n", table(["" | Enum.map(runs, & &1.name)], rows)]
  end

  defp share(_count, 0), do: "0 (0%)"
  defp share(count, total), do: "#{count} (#{round(100 * count / total)}%)"

  defp comparison(base, other, listed) do
    compared = compare(base, other)

    [
      "\n",
      base.name,
      " vs ",
      other.name,
      ": ",
      Integer.to_string(length(compared.shared)),
      " shared episodes, ",
      Integer.to_string(length(compared.only_here)),
      " only in ",
      base.name,
      ", ",
      Integer.to_string(length(compared.only_there)),
      " only in ",
      other.name,
      "\n",
      [
        "outcome agrees on ",
        agreed(compared.agreed, compared.shared),
        ", target found (TFNP) agrees on ",
        agreed(compared.found_agreed, compared.shared)
      ],
      [
        for(
          {column, delta} <- Enum.sort(compared.deltas),
          do: delta_line(base, other, column, delta)
        )
      ],
      disagreements(base, other, compared.disagreed, listed)
    ]
  end

  defp agreed(_count, []), do: "0/0"
  defp agreed(count, shared), do: "#{count}/#{length(shared)}"

  defp delta_line(base, other, column, delta) do
    [
      "\n",
      column,
      ": ",
      base.name,
      " - ",
      other.name,
      " mean ",
      short(delta.mean),
      ", median ",
      short(delta.median),
      " · lower in ",
      base.name,
      " ",
      Integer.to_string(delta.lower),
      ", higher ",
      Integer.to_string(delta.higher),
      ", equal ",
      Integer.to_string(delta.equal)
    ]
  end

  defp disagreements(_base, _other, [], _listed), do: []

  defp disagreements(base, other, disagreed, listed) do
    rows =
      disagreed
      |> Enum.take(listed)
      |> Enum.map(fn seed ->
        here = row(base, seed)
        there = row(other, seed)

        [
          Integer.to_string(seed),
          cut(Map.get(here, "primary_target_object", "-"), 16),
          judgement(here),
          judgement(there),
          steps(here) <> "/" <> steps(there),
          short(number(here, "num_steps")) <> "/" <> short(number(there, "num_steps")),
          short(number(here, "monty_steps")) <> "/" <> short(number(there, "monty_steps")),
          target_of(here),
          target_of(there)
        ]
      end)

    [
      "\n\nepisodes whose outcome differs (first #{listed} of #{length(disagreed)})\n",
      table(
        [
          "seed",
          "target",
          base.name,
          other.name,
          "steps (sensor)",
          "steps (modules)",
          "TFNP " <> base.name,
          "TFNP " <> other.name
        ],
        rows
      )
    ]
  end

  defp steps(row), do: short(number(row, "num_steps"))

  defp cut(text, length) when byte_size(text) <= length, do: text
  defp cut(text, length), do: binary_part(text, 0, length - 3) <> "..."

  defp short(nil), do: "-"
  defp short(value) when value == trunc(value) and abs(value) >= 1000, do: thousands(trunc(value))
  defp short(value) when value == trunc(value), do: Integer.to_string(trunc(value))
  defp short(value) when abs(value) >= 10, do: :erlang.float_to_binary(value, decimals: 1)

  defp short(value),
    do:
      value
      |> :erlang.float_to_binary(decimals: 3)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

  defp thousands(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  # Columns of a table, each as wide as its widest cell.
  defp table(header, rows) do
    widths =
      Enum.reduce([header | rows], [], fn row, widths ->
        row
        |> Enum.with_index()
        |> Enum.reduce(widths, fn {cell, index}, widths ->
          wide(widths, index, String.length(cell))
        end)
      end)

    Enum.map_join([header | rows], "", fn row ->
      row
      |> Enum.with_index()
      |> Enum.map_join("  ", fn {cell, index} ->
        String.pad_trailing(cell, Enum.at(widths, index))
      end)
      |> String.trim_trailing()
      |> Kernel.<>("\n")
    end)
  end

  # The width at `index`, widened to `length` — a row may be longer than any
  # row before it, which is why this appends rather than replaces.
  defp wide(widths, index, length) when index < length(widths),
    do: List.replace_at(widths, index, max(Enum.at(widths, index), length))

  defp wide(widths, index, length),
    do: widths ++ List.duplicate(0, index - length(widths)) ++ [length]

  defp short_name(path) do
    expanded = Path.expand(path)

    name =
      case Path.basename(expanded) do
        "eval_stats.csv" -> expanded |> Path.dirname() |> Path.basename()
        other -> other
      end

    if String.length(name) <= 28, do: name, else: String.slice(name, 0, 25) <> "..."
  end
end
