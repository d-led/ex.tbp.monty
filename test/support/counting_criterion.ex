defmodule Monty.Experiment.RecognitionStrategy.CountingCriterion do
  @moduledoc """
  A match criterion that answers a fixed verdict and says it was asked.

  Monty's `MatchCriteria` case hands the policy a mock criterion and then asserts
  it was called exactly once; this sends a message to the test process instead,
  so the number of times is something the case can count.
  """

  @doc "A criterion that answers `matched?`, and tells `pid` every time it is asked."
  @spec new(pid(), boolean()) :: {module(), term()}
  def new(pid, matched?) when is_pid(pid), do: {__MODULE__, {pid, matched?}}

  @doc "Monty's `criterion(terminal_states)`: the verdict, and one message."
  @spec matched?(map(), {pid(), boolean()}) :: boolean()
  def matched?(_states, {pid, matched?}) do
    send(pid, :criterion_asked)
    matched?
  end
end
