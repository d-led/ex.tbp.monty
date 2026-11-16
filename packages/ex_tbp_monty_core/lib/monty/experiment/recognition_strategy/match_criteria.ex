defmodule Monty.Experiment.RecognitionStrategy.MatchCriteria do
  @moduledoc """
  Done when the model's own match criterion is satisfied.

  Mirrors `tbp/monty/experiment/recognition_strategy.py::MatchCriteria`, which
  takes no configuration and asks the model: it hands the modules' terminal
  states to the criterion the model was built with
  (`Monty.Experiment.MatchCriteria`) and believes the answer. So this is the
  policy for an experiment that wants the system's usual notion of recognition
  rather than a step count.

  The criterion travels with the model, not with the strategy, because it is the
  model that decides what its modules agreeing means.
  """

  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  @doc "The policy, taking no configuration."
  @spec new(keyword()) :: {:ok, {module(), %{}}}
  def new(_options \\ []), do: {:ok, {__MODULE__, %{}}}

  @doc """
  Done — and timing out the laggards — when the criterion is met.

  Monty answers `time_out_lms: is_done` here: a satisfied criterion ends the
  episode, and a module that has not concluded takes that ending as its answer.
  """
  @spec call(map(), term(), map()) :: RecognitionResult.t()
  def call(model, _counter, _state) do
    {criterion, argument} = model.match_criterion
    matched? = criterion.matched?(model.terminal_states, argument)

    %RecognitionResult{is_done: matched?, time_out_lms: matched?}
  end
end
