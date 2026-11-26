defmodule Monty.Experiment.RecognitionStrategy.ObjectRecognition do
  @moduledoc """
  Monty's own object-recognition policy: two ways to finish an episode.

  Mirrors `tbp/monty/experiment/recognition_strategy.py::ObjectRecognition`, and
  is what `termination/any1_objectrecognition_t1000_e500_tot6000` configures. In
  Monty's order:

    1. the mode's matching limit is reached and the model is not exploring —
       done, and time the modules out beside it;
    2. the total step ceiling is reached — done, and time the modules out.

  Both time the modules out: an episode stopped by a limit still owes an answer.
  (The port used to have a third clause reading `model.is_done`, which Monty
  removed along with the model's own `is_done` — a strategy decides, the model
  no longer does.)
  """

  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  @doc """
  A policy with a matching limit per mode and a total ceiling.

  Monty raises `ValueError` for any limit that is not positive; here that is
  `{:error, message}` with Monty's own words, checked in the same order.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    max_train_steps = Keyword.fetch!(options, :max_train_steps)
    max_eval_steps = Keyword.fetch!(options, :max_eval_steps)
    max_total_steps = Keyword.fetch!(options, :max_total_steps)

    cond do
      max_train_steps <= 0 ->
        {:error, "max_train_steps must be positive"}

      max_eval_steps <= 0 ->
        {:error, "max_eval_steps must be positive"}

      max_total_steps <= 0 ->
        {:error, "max_total_steps must be positive"}

      true ->
        {:ok,
         {__MODULE__,
          %{
            max_train_steps: max_train_steps,
            max_eval_steps: max_eval_steps,
            max_total_steps: max_total_steps
          }}}
    end
  end

  @doc "The first of the two conditions that holds, in Monty's order."
  @spec call(map(), Monty.Experiment.RecognitionStrategy.RecognitionContext.t(), map()) ::
          RecognitionResult.t()
  def call(model, counter, state) do
    cond do
      not model.is_exploring and counter.matching_steps >= limit(state, counter.mode) ->
        %RecognitionResult{is_done: true, time_out_lms: true}

      counter.step >= state.max_total_steps ->
        %RecognitionResult{is_done: true, time_out_lms: true}

      true ->
        %RecognitionResult{}
    end
  end

  defp limit(%{max_train_steps: steps}, :train), do: steps
  defp limit(%{max_eval_steps: steps}, :eval), do: steps
end
