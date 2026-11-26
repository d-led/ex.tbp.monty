defmodule Monty.Experiment.RecognitionStrategy.Any do
  @moduledoc """
  Done when *any* of its strategies is, and it stops asking at the first yes.

  Mirrors `tbp/monty/experiment/recognition_strategy.py::Any`. The result is the
  union of the answers it did get: a `time_out_lms` from an earlier strategy
  survives a later one that says done on its own, so combining strategies never
  loses a request.

  Stopping at the first "done" is Monty's behaviour and it is observable — a
  strategy after the one that fired is not consulted at all — which is why the
  recording compares the union rather than re-running every member.
  """

  alias Monty.Experiment.RecognitionStrategy
  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  @doc """
  A strategy over `:strategies`, in the order they are asked.

  Monty raises `ValueError` for an empty list; here that is
  `{:error, "no strategies to check"}`.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    strategies = Keyword.get(options, :strategies, [])

    if strategies == [] do
      {:error, "no strategies to check"}
    else
      {:ok, {__MODULE__, %{strategies: strategies}}}
    end
  end

  @doc "The union of the answers, stopping at the first strategy that is done."
  @spec call(map(), RecognitionStrategy.RecognitionContext.t(), map()) :: RecognitionResult.t()
  def call(model, counter, %{strategies: strategies}) do
    Enum.reduce_while(strategies, %RecognitionResult{}, fn strategy, result ->
      result = union(result, RecognitionStrategy.call(strategy, model, counter))

      if result.is_done, do: {:halt, result}, else: {:cont, result}
    end)
  end

  defp union(result, answer) do
    %RecognitionResult{
      is_done: result.is_done or answer.is_done,
      time_out_lms: result.time_out_lms or answer.time_out_lms,
      start_exploring: result.start_exploring or answer.start_exploring,
      # False is the non-default, so the union is an `and` here.
      global_time_out: result.global_time_out and answer.global_time_out
    }
  end
end
