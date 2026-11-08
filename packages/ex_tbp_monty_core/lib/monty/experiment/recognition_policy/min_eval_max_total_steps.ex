defmodule Monty.Experiment.RecognitionPolicy.MinEvalMaxTotalSteps do
  @moduledoc """
  A wrapper that refuses to stop too early, and stops anyway at a ceiling.

  Mirrors `tbp/monty/experiment/recognition_policy.py::MinEvalMaxTotalSteps`. It
  exists because a model can recognise an object in three steps, which makes an
  evaluation measure nothing: this holds the episode open until
  `min_eval_steps` matching steps have happened, while still ending it at
  `max_total_steps` — which is also the guard against a policy that stalls
  because matching steps never increase.

  The wrapped policy's `time_out_lms` and `start_exploring` are carried through
  in every branch, so wrapping changes *when* an episode stops and nothing else.
  """

  alias Monty.Experiment.RecognitionPolicy
  alias Monty.Experiment.RecognitionPolicy.RecognitionResult

  @doc """
  A wrapper around `:wrapped`, which is a policy in the same `{module, state}`
  shape.

  Monty raises `ValueError` for a negative minimum, a non-positive ceiling, or a
  minimum above the ceiling; here that is `{:error, message}` with Monty's own
  words, checked in the same order.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    wrapped = Keyword.fetch!(options, :wrapped)
    min_eval_steps = Keyword.get(options, :min_eval_steps, 0)
    max_total_steps = Keyword.get(options, :max_total_steps, 1)

    cond do
      min_eval_steps < 0 ->
        {:error, "min_eval_steps must be non-negative"}

      max_total_steps <= 0 ->
        {:error, "max_total_steps must be positive"}

      min_eval_steps > max_total_steps ->
        {:error, "min_eval_steps must be less than or equal to max_total_steps"}

      true ->
        {:ok,
         {__MODULE__,
          %{
            wrapped: wrapped,
            min_eval_steps: min_eval_steps,
            max_total_steps: max_total_steps
          }}}
    end
  end

  @doc """
  The wrapped answer, held back while too little has been seen, or ended at the
  ceiling.
  """
  @spec call(map(), RecognitionPolicy.RecognitionCounter.t(), map()) ::
          RecognitionResult.t()
  def call(model, counter, state) do
    wrapped = RecognitionPolicy.call(state.wrapped, model, counter)

    cond do
      model.is_done ->
        %RecognitionResult{
          is_done: true,
          time_out_lms: wrapped.time_out_lms,
          start_exploring: wrapped.start_exploring
        }

      counter.step >= state.max_total_steps ->
        %RecognitionResult{
          is_done: true,
          time_out_lms: true,
          start_exploring: wrapped.start_exploring
        }

      counter.mode == :eval and counter.matching_steps < state.min_eval_steps ->
        %RecognitionResult{
          is_done: false,
          time_out_lms: wrapped.time_out_lms,
          start_exploring: wrapped.start_exploring
        }

      true ->
        wrapped
    end
  end
end
