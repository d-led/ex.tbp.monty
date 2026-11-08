defmodule Monty.Experiment.MatchCriteria.AnyLMsMatch do
  @moduledoc """
  Satisfied once any `count` learning modules have recognised an object.

  Mirrors `tbp/monty/experiment/match_criteria.py::AnyLMsMatch`. This is the
  criterion a single-module experiment uses with `count: 1`: the one module
  matched, so Monty has recognised the object. With several modules it is a
  quorum — two of five columns agreeing is enough.

  A `count` below one would be satisfied before anything was seen, so it is
  refused when the criterion is built.
  """

  @behaviour Monty.Experiment.MatchCriteria.MatchCriterion

  alias Monty.Experiment.MatchCriteria.MatchCriterion

  @type t :: %__MODULE__{count: pos_integer()}

  @enforce_keys [:count]
  defstruct [:count]

  @doc "A criterion that needs `count` modules to match."
  @spec new(pos_integer()) :: {:ok, t()} | {:error, :count_must_be_positive}
  def new(count) when is_integer(count) and count > 0, do: {:ok, %__MODULE__{count: count}}
  def new(_count), do: {:error, :count_must_be_positive}

  @impl MatchCriterion
  @spec matched?(MatchCriterion.terminal_states(), t()) :: boolean()
  def matched?(terminal_states, %__MODULE__{count: count}) do
    Enum.count(terminal_states, fn {_module_id, state} -> state == :match end) >= count
  end
end
