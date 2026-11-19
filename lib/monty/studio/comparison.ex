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
          rows: [row()]
        }

  # The summary's numbers, in the order a reader compares them: how far the run
  # got, then what it cost, then the two counters that say whether the schedule
  # lost anything on the way.
  @measures [
    {"Steps", "steps"},
    {"Model time", "duration_us"},
    {"World time", "world_us"},
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
       rows: rows(a, b)
     }}
  end

  def compare(%{experiment: a_experiment}, %{experiment: b_experiment}) do
    {:error, {:different_experiments, a_experiment, b_experiment}}
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
