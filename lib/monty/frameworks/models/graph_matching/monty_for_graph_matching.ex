defmodule Monty.Frameworks.Models.GraphMatching.MontyForGraphMatching do
  @moduledoc """
  What the graph-matching model does rather than owns: the vote round.

  Mirrors `tbp/monty/frameworks/models/graph_matching.py::MontyForGraphMatching`,
  whose `_combine_votes` is the one piece of that class that is arithmetic rather
  than message passing — this runtime does the message passing
  (`Monty.Runtime.Step`), so the arithmetic is what is left to port.

  ## Two kinds of vote, and why this is the union

  A module of this family names the objects it has **ruled out**
  (`GraphLM.send_out_vote/1`), so what a receiver hears from several modules is
  the union of what each ruled out: one module's doubt is not another's
  confidence, and a sum of sets is not a thing.

  The evidence family votes the other way round — it names the hypotheses it
  still believes, with the pose and location each implies
  (`MontyForEvidenceGraphMatching.combine_votes/2`) — and that is a different
  calculation over a different shape. Monty's own `_combine_votes` branches on
  exactly this (`isinstance(votes_per_lm[0], set)`), and so does
  `Monty.Runtime.Step.State.combine_votes/2`: one model class drives both
  families in Monty, and the shape of a vote is what tells it which calculation
  to run.

  ## What a silent module contributes

  Nothing. A module with no opinion — or one whose vote did not arrive before
  the deadline — is `nil` in the reply map, and `nil` is not an empty set: the
  empty set is a module that considered every object and ruled all of them in.
  Union is the same either way, which is why this is a `reject` and not a
  special case.
  """

  @typedoc "A module's vote: the objects it has ruled out, or `nil` for silence."
  @type vote :: MapSet.t() | nil

  @doc """
  What each module hears, given every module's vote and the vote matrix.

  Keyed by receiver, then a list of object names — the shape
  `GraphLM.receive_votes/2` reads. A module the matrix gives no sources answers
  `[]`, which is Monty's empty union.
  """
  @spec combine_votes(%{optional(term()) => vote()}, %{optional(term()) => [term()]}) ::
          %{optional(term()) => [term()]}
  def combine_votes(votes, lm_to_lm_vote) do
    Map.new(lm_to_lm_vote, fn {receiver, sources} ->
      {receiver, ruled_out_by(votes, sources)}
    end)
  end

  defp ruled_out_by(votes, sources) do
    sources
    |> Enum.map(&Map.get(votes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> MapSet.to_list()
  end
end
