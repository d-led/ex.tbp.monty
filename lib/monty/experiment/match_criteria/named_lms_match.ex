defmodule Monty.Experiment.MatchCriteria.NamedLMsMatch do
  @moduledoc """
  Satisfied once every named learning module has recognised an object.

  Mirrors `tbp/monty/experiment/match_criteria.py::NamedLMsMatch`. An
  experiment whose answer depends on particular columns — a hierarchy where the
  top module must confirm what the one below it proposed — names them here, so
  that a match elsewhere does not end the episode.

  An empty set of ids would be satisfied before anything was seen, so it is
  refused when the criterion is built.
  """

  @behaviour Monty.Experiment.MatchCriteria.MatchCriterion

  alias Monty.Experiment.MatchCriteria.MatchCriterion

  @type t :: %__MODULE__{ids: MapSet.t(String.t())}

  @enforce_keys [:ids]
  defstruct [:ids]

  @doc "A criterion that needs exactly these modules to match."
  @spec new([String.t()]) :: {:ok, t()} | {:error, :ids_must_not_be_empty}
  def new([]), do: {:error, :ids_must_not_be_empty}

  def new(ids), do: {:ok, %__MODULE__{ids: MapSet.new(ids)}}

  @impl MatchCriterion
  @spec matched?(MatchCriterion.terminal_states(), t()) :: boolean()
  def matched?(terminal_states, %__MODULE__{ids: ids}) do
    Enum.all?(ids, fn id -> Map.get(terminal_states, id) == :match end)
  end
end
