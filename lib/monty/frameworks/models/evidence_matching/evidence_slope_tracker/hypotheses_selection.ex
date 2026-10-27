defmodule Monty.Frameworks.Models.EvidenceMatching.EvidenceSlopeTracker.HypothesesSelection do
  @moduledoc """
  Which hypotheses a slope threshold keeps, as a mask and as indices.

  Mirrors `evidence_slope_tracker.py::HypothesesSelection`. The mask is the
  thing that was decided; the two index lists are what a caller acts on, and
  keeping them here means "retained" and "removed" cannot drift apart.
  """

  @enforce_keys [:mask]
  defstruct [:mask]

  @type t :: %__MODULE__{mask: [boolean()]}

  @doc "A selection from a mask, `true` meaning the hypothesis is kept."
  @spec new([boolean()]) :: t()
  def new(mask), do: %__MODULE__{mask: Enum.map(mask, &(&1 == true))}

  @doc "The indices of the hypotheses to keep, in order."
  @spec ids_to_retain(t()) :: [non_neg_integer()]
  def ids_to_retain(%__MODULE__{mask: mask}), do: indices_where(mask, true)

  @doc "The indices of the hypotheses to remove, in order."
  @spec ids_to_remove(t()) :: [non_neg_integer()]
  def ids_to_remove(%__MODULE__{mask: mask}), do: indices_where(mask, false)

  @doc "How many hypotheses the selection is about."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{mask: mask}), do: length(mask)

  defp indices_where(mask, wanted) do
    mask
    |> Enum.with_index()
    |> Enum.filter(fn {value, _index} -> value == wanted end)
    |> Enum.map(fn {_value, index} -> index end)
  end
end
