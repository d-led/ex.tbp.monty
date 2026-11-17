defmodule Monty.Studio.Verdict do
  @moduledoc """
  What a run's learning modules concluded at one step, and whether they agreed.

  Monty ends an episode on the first module that matches
  (`MatchCriteria.AnyLMsMatch`), and every module still working is then timed
  out — so a run of five modules records one `match` and four `time_out`, and
  "did they agree" is not a question the last report answers. It is a question
  the record answers: each module's own terminal state, and the object it named.

  A module that ran out of steps is **not** a module that disagreed. It held a
  belief when the episode ended, and a parallel run is read for whether the
  modules that concluded named the same object, with the rest named as still
  believing theirs. Silence is reported as silence.

  The states are read as the record writes them, which is as strings — the
  database hands back what it was given, and one shape keeps a replay of a live
  run and a replay of a stored one the same picture.
  """

  @typedoc """
  One module's answer at the step: what it concluded (`nil` while undecided) and
  the object it named — the concluded object for a match, the one it still
  believed most for a module that was timed out.
  """
  @type result :: %{
          module_id: String.t(),
          state: String.t() | nil,
          object: String.t() | nil
        }

  @typedoc """
  `object` is the object the concluded modules named, and `agreed?` says whether
  they all named it. No module concluded at this step is `object: nil` with
  `agreed?: false` — a step with no answer is not an agreement.
  """
  @type t :: %{
          object: String.t() | nil,
          agreed?: boolean(),
          concluded: [result()],
          dissent: [result()],
          undecided: [result()]
        }

  @doc """
  The verdict of one step's beliefs, or `nil` for a step that reported none.

  `beliefs` is the record's own shape: module id to what the module held, with
  `"terminal_state"`, `"detected_object"` and its graphs.
  """
  @spec of(%{optional(String.t()) => map()}) :: t() | nil
  def of(beliefs) when map_size(beliefs) == 0, do: nil

  def of(beliefs) do
    results =
      beliefs
      |> Enum.map(fn {module_id, belief} -> result(to_string(module_id), belief) end)
      |> Enum.sort_by(& &1.module_id)

    {concluded, rest} = Enum.split_with(results, &(&1.state == "match"))

    # A module that concluded "no object is here" is not still believing one, and
    # it is not a dissent either: it refused the object, which is a different
    # answer from naming another.
    {dissent, undecided} = Enum.split_with(rest, &(&1.state == "no_match"))

    names = concluded |> Enum.map(& &1.object) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      # The object they agreed on, and nothing when they did not: a verdict that
      # named the first module's object would say "agreed" about a disagreement.
      object: if(length(names) == 1, do: hd(names), else: nil),
      agreed?: length(names) == 1,
      concluded: concluded,
      dissent: dissent,
      undecided: undecided
    }
  end

  defp result(module_id, belief) do
    state = belief |> Map.get("terminal_state") |> normalised()

    %{module_id: module_id, state: state, object: named(belief, state)}
  end

  # A concluded module named the object it matched; one still working names the
  # object it holds at the moment the episode ended, which is its last belief.
  defp named(belief, "match"), do: Map.get(belief, "detected_object") || believed(belief)
  defp named(_belief, "no_match"), do: nil
  defp named(belief, _undecided), do: believed(belief)

  # The object a module held, from its current hypothesis where the record kept
  # one and from the strongest graph otherwise: a module whose hypothesis was
  # never built still has graphs, and its strongest is what it believed.
  defp believed(belief) do
    case get_in(belief, ["mlh", "graph_id"]) do
      nil -> strongest(belief)
      graph_id -> graph_id
    end
  end

  defp strongest(belief) do
    case Map.get(belief, "graphs", %{}) do
      graphs when map_size(graphs) == 0 ->
        nil

      graphs ->
        {name, _graph} =
          Enum.max_by(graphs, fn {_name, graph} ->
            Map.get(graph, "max_evidence") || 0
          end)

        name
    end
  end

  defp normalised(nil), do: nil
  defp normalised(state), do: to_string(state)
end
