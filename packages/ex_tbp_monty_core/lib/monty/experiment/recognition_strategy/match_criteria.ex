defmodule Monty.Experiment.RecognitionStrategy.MatchCriteria do
  @moduledoc """
  Done when the modules satisfy the criterion this policy carries.

  Mirrors `tbp/monty/experiment/recognition_strategy.py::MatchCriteria`. The
  criterion is the policy's own configuration — it used to read the model's,
  and Monty's TODO to move it here has been taken — so the modules' terminal
  states go to it and its answer is the decision, with the modules that have
  not concluded taking the ending as theirs.

  So this is the policy for an experiment that wants the system's usual notion
  of recognition rather than a step count.
  """

  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  @doc """
  The policy with a match criterion, built by `Monty.Experiment.MatchCriteria`.

  Monty's constructor takes the criterion as its only argument; one that is
  missing is refused rather than defaulted.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    case Keyword.fetch(options, :match_criterion) do
      {:ok, criterion} -> {:ok, {__MODULE__, %{match_criterion: criterion}}}
      :error -> {:error, "a match-criteria policy needs match_criterion"}
    end
  end

  @doc """
  Done — and timing out the laggards — when the criterion is met.

  Monty answers `time_out_lms: is_done` here: a satisfied criterion ends the
  episode, and a module that has not concluded takes that ending as its answer.
  """
  @spec call(map(), Monty.Experiment.RecognitionStrategy.RecognitionContext.t(), map()) ::
          RecognitionResult.t()
  def call(model, _counter, state) do
    {criterion, argument} = state.match_criterion
    matched? = criterion.matched?(model.terminal_states, argument)

    %RecognitionResult{is_done: matched?, time_out_lms: matched?}
  end
end
