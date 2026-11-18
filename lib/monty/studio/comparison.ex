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
     %{sides: [a.name, b.name], differences: differences(a.inputs, b.inputs), rows: rows(a, b)}}
  end

  def compare(%{experiment: a_experiment}, %{experiment: b_experiment}) do
    {:error, {:different_experiments, a_experiment, b_experiment}}
  end

  @doc """
  The input keys whose values differ, as sentences-ready names.

  An input only one run has is a difference too: a run started before the lever
  existed and one started after it are not the same run twice.
  """
  @spec differences(map(), map()) :: [String.t()]
  def differences(a, b) when is_map(a) and is_map(b) do
    (Map.keys(a) ++ Map.keys(b))
    |> Enum.uniq()
    |> Enum.filter(fn key -> Map.get(a, key) != Map.get(b, key) end)
    |> Enum.sort()
  end

  def differences(_a, _b), do: []

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
