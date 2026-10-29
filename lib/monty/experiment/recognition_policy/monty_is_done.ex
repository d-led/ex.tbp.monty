defmodule Monty.Experiment.RecognitionPolicy.MontyIsDone do
  @moduledoc """
  The original policy: the model says it is done, or it does not.

  Mirrors `tbp/monty/experiment/recognition_policy.py::MontyIsDone`, which is
  what Monty uses when a config names no policy at all — so this is the floor
  every experiment stands on, and the one an episode with no step limit falls
  back to.
  """

  alias Monty.Experiment.RecognitionPolicy.RecognitionResult

  @doc "The policy, taking no configuration — which is why it cannot refuse one."
  @spec new() :: {:ok, {module(), %{}}}
  def new, do: {:ok, {__MODULE__, %{}}}

  @doc "Done when the model says so; asks no other question."
  @spec call(map(), term(), map()) :: RecognitionResult.t()
  def call(model, _counter, _state), do: %RecognitionResult{is_done: model.is_done}
end
