defmodule Monty.Experiment.RecognitionPolicy.AnyPolicy do
  @moduledoc """
  Done when *any* of its policies is, and it stops asking at the first yes.

  Mirrors `tbp/monty/experiment/recognition_policy.py::AnyPolicy`. The result is
  the union of the answers it did get: a `time_out_lms` from an earlier policy
  survives a later one that says done on its own, so combining policies never
  loses a request.

  Stopping at the first "done" is Monty's behaviour and it is observable — a
  policy after the one that fired is not consulted at all — which is why the
  recording compares the union rather than re-running every member.
  """

  alias Monty.Experiment.RecognitionPolicy
  alias Monty.Experiment.RecognitionPolicy.RecognitionResult

  @doc """
  A policy over `:policies`, in the order they are asked.

  Monty raises `ValueError` for an empty list; here that is
  `{:error, "no policies to check"}`.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    policies = Keyword.fetch!(options, :policies)

    if policies == [] do
      {:error, "no policies to check"}
    else
      {:ok, {__MODULE__, %{policies: policies}}}
    end
  end

  @doc "The union of the answers, stopping at the first policy that is done."
  @spec call(map(), RecognitionPolicy.RecognitionCounter.t(), map()) :: RecognitionResult.t()
  def call(model, counter, %{policies: policies}) do
    Enum.reduce_while(policies, %RecognitionResult{}, fn policy, result ->
      answer = RecognitionPolicy.call(policy, model, counter)
      result = union(result, answer)

      if result.is_done, do: {:halt, result}, else: {:cont, result}
    end)
  end

  defp union(result, answer) do
    %RecognitionResult{
      is_done: result.is_done or answer.is_done,
      time_out_lms: result.time_out_lms or answer.time_out_lms,
      start_exploring: result.start_exploring or answer.start_exploring
    }
  end
end
