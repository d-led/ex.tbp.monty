defmodule Monty.Experiment.RecognitionPolicy.MontyIsDone do
  @moduledoc """
  The original policy: the model says it is done, or it does not.

  Mirrors `tbp/monty/experiment/recognition_policy.py::MontyIsDone`, which is
  what Monty uses when a config names no policy at all — so this is the floor
  every experiment stands on, and the one an episode with no step limit falls
  back to.
  """

  alias Monty.Experiment.RecognitionPolicy.RecognitionResult

  @doc """
  The policy, taking no configuration.

  Monty's constructor takes no arguments either; the empty option list is here
  so that every policy is built the same way, and an option is still refused —
  by the factory, before this is asked (`Monty.Experiment.RecognitionPolicy`).
  """
  @spec new(keyword()) :: {:ok, {module(), %{}}}
  def new(_options \\ []), do: {:ok, {__MODULE__, %{}}}

  @doc "Done when the model says so; asks no other question."
  @spec call(map(), term(), map()) :: RecognitionResult.t()
  def call(model, _counter, _state), do: %RecognitionResult{is_done: model.is_done}
end
