defmodule Monty.Studio.Comparison do
  @moduledoc """
  Two runs of one experiment, side by side.

  The page can start the same experiment twice with one input apart — the sensor
  round, the scheduling of a step — and the question that follows is what the
  lever bought. This is that answer: each run's own numbers, one column a run,
  and the inputs that differ named above them, because a table of two runs whose
  inputs nobody named is a table a reader has to guess about.

  A comparison of two *different* experiments is refused. Their numbers differ
  for a reason that has nothing to do with the lever, and calling it an
  improvement would be the wrong answer twice.

  Nothing here reads a run. A side is a run's name, experiment, inputs and
  `summary` — the map `Monty.Studio.RunLog.summary/2` writes — so the page that
  has the records and a test that has two maps ask the same function.
  """

  alias Monty.Studio.StepShape

  @type side :: %{
          required(:name) => String.t(),
          required(:experiment) => String.t(),
          required(:inputs) => map(),
          required(:summary) => map(),
          optional(atom()) => term()
        }

  @type row :: %{label: String.t(), a: term(), b: term()}

  @type t :: %{
          sides: [String.t()],
          differences: [String.t()],
          unrecorded: [String.t()],
          shapes: [{String.t(), [String.t()]}],
          rows: [row()]
        }

  # The summary's numbers, in the order a reader compares them: how far the run
  # got, then what it cost, then the two counters that say whether the schedule
  # lost anything on the way. "Episode time" is the statistics file's own — the
  # sum of an episode's elapsed time — and a side that has no statistics file
  # leaves the row out rather than guessing at it.
  @measures [
    {"Steps", "steps"},
    {"Model time", "duration_us"},
    {"World time", "world_us"},
    {"Episode time", "episode_us"},
    {"Wall clock", "wall_us"},
    {"Deadline hits", "deadline_hits"}
  ]

  @doc """
  The two runs' numbers and the inputs that differ, or why they cannot be compared.
  """
  @spec compare(side(), side()) ::
          {:ok, t()} | {:error, {:different_experiments, String.t(), String.t()}}
  def compare(%{experiment: experiment} = a, %{experiment: experiment} = b) do
    {:ok,
     %{
       sides: [a.name, b.name],
       differences: differences(a.inputs, b.inputs),
       unrecorded: unrecorded(a.inputs, b.inputs),
       # What each side's step numbers are a measurement of. Two runs of one seed
       # with one lever moved are this page's whole purpose, and the lever is
       # exactly a change to what a number means — so the meaning travels with
       # the comparison rather than being left to a reader who knows the levers.
       shapes: shapes(a, b),
       rows: rows(a, b)
     }}
  end

  def compare(%{experiment: a_experiment}, %{experiment: b_experiment}) do
    {:error, {:different_experiments, a_experiment, b_experiment}}
  end

  @doc """
  A side built from a run's — or a part's — statistics file.

  A part has no summary: its numbers are the `eval_stats.csv` it wrote in its own
  directory, which is also what a whole run's merged file is made of. So a
  comparison that reads one side from a summary and the other from a file would
  be two vocabularies in one table, and a part would answer "no steps" beside a
  run's thousands. When either side is a part, both are read this way, and the
  table says so.

  The shape is the summary's — steps, the episode's time, and one conclusion per
  module, counted by the episode's own exit — so the page draws one table either
  way.
  """
  @spec from_stats(String.t(), String.t(), map(), Monty.Studio.EvalStats.t(), integer() | nil) ::
          side()
  def from_stats(name, experiment, inputs, stats, wall_us \\ nil) do
    episodes = episodes_of(stats)

    %{
      name: name,
      experiment: experiment,
      inputs: inputs,
      summary:
        Map.merge(
          %{
            "steps" => Enum.sum(Enum.map(episodes, &count_of(&1, "num_steps"))),
            "episode_us" => Enum.sum(Enum.map(episodes, &seconds_as_microseconds(&1, "time")))
          },
          conclusions_of(stats.rows)
        ),
      wall_us: wall_us
    }
  end

  # One row an episode: a statistics file writes a row per module, and counting
  # a module's copy of the episode's steps once per module would report a run of
  # five modules as five times its length. `by_seed` is the reader's own index of
  # the episodes it could join on; a file too old to carry a seed has no better
  # grouping than its rows.
  defp episodes_of(%{seeded?: true, by_seed: by_seed}), do: Map.values(by_seed)
  defp episodes_of(%{rows: rows}), do: rows

  defp count_of(row, column) do
    case row |> Map.get(column, "") |> String.trim() |> Integer.parse() do
      {count, ""} -> count
      _not_a_count -> 0
    end
  end

  defp seconds_as_microseconds(row, column) do
    case row |> Map.get(column, "") |> String.trim() |> Float.parse() do
      {seconds, ""} -> round(seconds * 1_000_000)
      _not_a_duration -> 0
    end
  end

  # What each module concluded, in the words the statistics file uses and in the
  # shape a summary holds: one entry a state, and one for the module's last
  # answer.
  defp conclusions_of(rows) do
    by_module = Enum.group_by(rows, &module_of/1, &Monty.Studio.EvalStats.exit_of/1)

    outcomes =
      Map.new(by_module, fn {module, exits} -> {module, Enum.frequencies(exits)} end)

    last =
      Map.new(by_module, fn {module, exits} -> {module, List.last(exits)} end)

    %{"outcomes" => outcomes, "outcome" => last}
  end

  defp module_of(row) do
    case row |> Map.get("lm_id", "") |> String.trim() do
      "" -> "learning module"
      module -> module
    end
  end

  @doc """
  The inputs both runs record, and whose values differ.

  What a reader is told first, because it is the answer to the question the page
  asks: what did I change? A key only one of the two holds is *not* here — nobody
  changed it, one record simply predates the lever — and is answered by
  `unrecorded/2`. Reporting the two together said "the inputs that differ: parts"
  of a pair in which both ran one part, and a reader has no way to see that the
  second run was merely started after that field existed.
  """
  @spec differences(map(), map()) :: [String.t()]
  def differences(a, b) when is_map(a) and is_map(b) do
    a = comparable(a)
    b = comparable(b)

    a
    |> Map.keys()
    |> Enum.filter(&(Map.has_key?(b, &1) and Map.get(a, &1) != Map.get(b, &1)))
    |> Enum.sort()
  end

  def differences(_a, _b), do: []

  # Each side that has something to say about how its numbers were measured, in
  # the words of the numbers: a side of Monty's own shape says nothing, because
  # there is nothing to explain.
  defp shapes(a, b) do
    for side <- [a, b],
        sentences = StepShape.sentences(side.inputs || %{}),
        sentences != [] do
      {side.name, sentences}
    end
  end

  # The division of a run is an input a reader compares — one part against four is
  # a different experiment — but each part also carries the id of the stream that
  # collected its steps, and that id is new for every run. Compared whole, "parts"
  # differed between *any* two runs, and the page told a reader they had changed
  # the division when they had not. What is compared is the division: how many
  # parts, of how many, in which phase.
  defp comparable(%{"parts" => parts} = inputs) when is_list(parts) do
    division = Enum.map(parts, &Map.take(&1, ["index", "of", "phase"]))
    Map.put(inputs, "parts", division)
  end

  defp comparable(inputs), do: inputs

  @doc """
  The inputs one run records and the other does not.

  Said in its own sentence because it means something else: a run started before a
  lever existed and one started after it are not the same run twice, and neither is
  it a change to the experiment.
  """
  @spec unrecorded(map(), map()) :: [String.t()]
  def unrecorded(a, b) when is_map(a) and is_map(b) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.filter(&(Map.has_key?(a, &1) != Map.has_key?(b, &1)))
    |> Enum.sort()
  end

  def unrecorded(_a, _b), do: []

  defp rows(a, b) do
    Enum.flat_map(@measures, fn {label, key} ->
      case {measure(a, key), measure(b, key)} do
        {nil, nil} -> []
        {left, right} -> [%{label: label, a: left, b: right}]
      end
    end) ++ conclusions(a, b)
  end

  # Wall clock is not in the summary — it is the record's own two instants, which
  # the page has and the summary does not — so a side may carry it beside them.
  defp measure(side, "wall_us"), do: Map.get(side, :wall_us)

  defp measure(side, key) do
    case side.summary do
      %{^key => value} -> value
      _not_reported -> nil
    end
  end

  # What each learning module concluded, module by module, so a run that lost one
  # object beside one that lost none is visible as the pair it is — and then, under
  # it, how many episodes of each state that module reached. The last conclusion
  # alone hides a run that lost two of five.
  defp conclusions(a, b) do
    module_ids = module_ids(a, b)

    Enum.map(module_ids, fn id ->
      %{label: "#{id} concluded", a: concluded(a, id), b: concluded(b, id)}
    end) ++ counts(a, b, module_ids)
  end

  defp counts(a, b, module_ids) do
    for id <- module_ids, state <- states(a, b, id) do
      %{label: "#{id} #{state}", a: count(a, id, state), b: count(b, id, state)}
    end
  end

  defp module_ids(a, b) do
    (summary_keys(a, "outcome") ++
       summary_keys(b, "outcome") ++ summary_keys(a, "outcomes") ++ summary_keys(b, "outcomes"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A state either run reached, so a state only one of them reached is a row with
  # a zero — which is the comparison, not a gap in the table.
  defp states(a, b, id) do
    (states_of(a, id) ++ states_of(b, id))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp states_of(side, id) do
    case side.summary do
      %{"outcomes" => %{^id => %{} = counted}} -> Map.keys(counted)
      _not_reported -> []
    end
  end

  defp count(side, id, state) do
    case side.summary do
      %{"outcomes" => %{^id => %{^state => count}}} -> count
      _not_reported -> 0
    end
  end

  defp summary_keys(side, key) do
    case side.summary do
      %{^key => %{} = conclusions} -> Map.keys(conclusions)
      _not_reported -> []
    end
  end

  defp concluded(side, id) do
    case side.summary do
      %{"outcome" => %{^id => terminal}} -> terminal
      _not_reported -> nil
    end
  end
end
