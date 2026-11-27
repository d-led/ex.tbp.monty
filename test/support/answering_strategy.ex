defmodule Monty.Experiment.RecognitionStrategy.Answering do
  @moduledoc """
  A recognition strategy that answers what it was made with.

  Monty's cases hold a strategy inside another one by handing the outer one a
  `MagicMock(RecognitionStrategy, return_value=…)`; this is the same thing with
  Monty's call shape — a policy is `{module, state}`, and `RecognitionStrategy.call/3`
  asks the module for its answer.
  """

  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  @doc "A policy that always answers `result`."
  @spec new(RecognitionResult.t()) :: {:ok, {module(), map()}}
  def new(%RecognitionResult{} = result), do: {:ok, {__MODULE__, %{result: result}}}

  @doc "The answer it was made with; the model and the counters are not read."
  @spec call(map(), term(), map()) :: RecognitionResult.t()
  def call(_model, _counter, %{result: result}), do: result
end
