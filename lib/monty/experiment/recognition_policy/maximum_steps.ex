defmodule Monty.Experiment.RecognitionPolicy.MaximumSteps do
  @moduledoc """
  Done once the *matching* steps reach the limit for the current mode.

  Mirrors `tbp/monty/experiment/recognition_policy.py::MaximumSteps`. Two things
  have to hold: the model is not exploring — an exploring step is training, not
  matching — and `model.matching_steps` has reached `max_train_steps` or
  `max_eval_steps`, chosen by mode.
  """

  alias Monty.Experiment.RecognitionPolicy.RecognitionResult

  @doc """
  A policy with a limit for each mode.

  Monty raises `ValueError` for a limit that is not positive; here that is
  `{:error, message}` with Monty's own words.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    max_train_steps = Keyword.fetch!(options, :max_train_steps)
    max_eval_steps = Keyword.fetch!(options, :max_eval_steps)

    cond do
      max_train_steps <= 0 ->
        {:error, "max_train_steps must be positive"}

      max_eval_steps <= 0 ->
        {:error, "max_eval_steps must be positive"}

      true ->
        {:ok, {__MODULE__, %{max_train_steps: max_train_steps, max_eval_steps: max_eval_steps}}}
    end
  end

  @doc "Done when the mode's limit is reached, unless the model is exploring."
  @spec call(map(), Monty.Experiment.RecognitionPolicy.RecognitionCounter.t(), map()) ::
          RecognitionResult.t()
  def call(model, counter, state) do
    is_done = not model.is_exploring and model.matching_steps >= limit(state, counter.mode)
    %RecognitionResult{is_done: is_done, time_out_lms: is_done}
  end

  defp limit(%{max_train_steps: steps}, :train), do: steps
  defp limit(%{max_eval_steps: steps}, :eval), do: steps
end
