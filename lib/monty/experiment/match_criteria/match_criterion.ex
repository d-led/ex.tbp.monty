defmodule Monty.Experiment.MatchCriteria.MatchCriterion do
  @moduledoc """
  What a match criterion is.

  Mirrors `tbp/monty/experiment/match_criteria.py::MatchCriterion`, a protocol
  for a callable that takes the terminal states of every learning module and
  answers whether the system has recognised the object.

  Monty's terminal states are strings; here they are atoms
  (`:match`, `:no_match`, `:time_out`, `:pose_time_out`), and a module that has
  not concluded yet is `nil`.
  """

  @type terminal_state :: :match | :no_match | :time_out | :pose_time_out | nil
  @type terminal_states :: %{optional(String.t()) => terminal_state()}

  @doc """
  Whether the terminal states amount to a recognition.

  Called with the criterion's own configuration as the second argument, so a
  criterion that needs a count or a set of module ids carries it as data rather
  than in its module.
  """
  @callback matched?(terminal_states(), term()) :: boolean()
end
