defmodule Monty.Frameworks.Models.EvidenceMatching.Hypotheses do
  @moduledoc """
  A set of hypotheses: their evidence, the location each implies, the pose each
  implies, and whether each can still be possible.

  Mirrors `tbp/monty/frameworks/models/evidence_matching/hypotheses.py`. The
  four fields are parallel — an index is one hypothesis in all of them — which
  is why Monty keeps them as separate arrays rather than a list of records: a
  learning module selects, masks and weights whole columns of them with one
  operation.

  In Elixir the arrays are lists, one entry per hypothesis, in the same order:
  `evidence` numbers, `locations` `[x, y, z]` in metres, `poses` 3×3 rotations,
  `possible` booleans. `empty/0` is the identity for `concatenate/1`, which is
  what lets a learning module build a step's hypotheses from however many
  sources voted.
  """

  @enforce_keys [:evidence, :locations, :poses, :possible]
  defstruct [:evidence, :locations, :poses, :possible]

  @type location :: [float()]
  @type pose :: [[float()]]

  @type t :: %__MODULE__{
          evidence: [float()],
          locations: [location()],
          poses: [pose()],
          possible: [boolean()]
        }

  @doc "The hypotheses of nothing: the identity for `concatenate/1`."
  @spec empty() :: t()
  def empty, do: %__MODULE__{evidence: [], locations: [], poses: [], possible: []}

  @doc """
  One set of hypotheses from several, in order.

  Monty concatenates along the hypothesis axis, so votes from two learning
  modules produce their votes first and the receiving module's hypotheses
  second, in the order the caller passes them.
  """
  @spec concatenate([t()]) :: t()
  def concatenate(hyps) do
    %__MODULE__{
      evidence: Enum.flat_map(hyps, & &1.evidence),
      locations: Enum.flat_map(hyps, & &1.locations),
      poses: Enum.flat_map(hyps, & &1.poses),
      possible: Enum.flat_map(hyps, & &1.possible)
    }
  end

  @doc "How many hypotheses the set holds."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{evidence: evidence}), do: length(evidence)

  @doc """
  The hypotheses at the given indices, in the order asked for.

  Used by a learning module to keep the hypotheses it still considers possible
  without rebuilding four lists by hand.
  """
  @spec take(t(), [non_neg_integer()]) :: t()
  def take(%__MODULE__{} = hypotheses, indices) do
    # One pass to tuples, then a constant-time lookup per index: reading them
    # out of lists by index walks the list every time, which over a hypothesis
    # space of thousands turns a selection into tens of millions of steps.
    evidence = List.to_tuple(hypotheses.evidence)
    locations = List.to_tuple(hypotheses.locations)
    poses = List.to_tuple(hypotheses.poses)
    possible = List.to_tuple(hypotheses.possible)

    %__MODULE__{
      evidence: Enum.map(indices, &elem(evidence, &1)),
      locations: Enum.map(indices, &elem(locations, &1)),
      poses: Enum.map(indices, &elem(poses, &1)),
      possible: Enum.map(indices, &elem(possible, &1))
    }
  end
end
