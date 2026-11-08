defmodule Monty.Experiment.RecognitionPolicy.StepLimit do
  @moduledoc """
  Three limits in one policy: matching, exploring, and when to start exploring.

  Mirrors `tbp/monty/experiment/recognition_policy.py::StepLimit`. Which limit
  applies depends on what the model is doing:

    * exploring — `exploring_steps` against `num_exploring_steps`;
    * training — `matching_steps` against `max_train_steps`, and once
      `min_train_steps` have matched it also asks to *start* exploring, which is
      how a training episode moves on to the next view of an object it knows;
    * evaluating — `matching_steps` against `max_eval_steps`.
  """

  alias Monty.Experiment.RecognitionPolicy.RecognitionResult

  @doc """
  A policy with the three limits.

  Monty raises `ValueError` for a negative minimum or a non-positive maximum;
  here that is `{:error, message}` with Monty's own words, checked in the same
  order Monty checks them.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    min_train_steps = Keyword.get(options, :min_train_steps, 0)
    num_exploring_steps = Keyword.get(options, :num_exploring_steps, 0)
    max_train_steps = Keyword.get(options, :max_train_steps, 1)
    max_eval_steps = Keyword.get(options, :max_eval_steps, 1)

    cond do
      min_train_steps < 0 ->
        {:error, "min_train_steps must be non-negative"}

      num_exploring_steps < 0 ->
        {:error, "num_exploring_steps must be non-negative"}

      max_train_steps <= 0 ->
        {:error, "max_train_steps must be positive"}

      max_eval_steps <= 0 ->
        {:error, "max_eval_steps must be positive"}

      true ->
        {:ok,
         {__MODULE__,
          %{
            min_train_steps: min_train_steps,
            num_exploring_steps: num_exploring_steps,
            max_train_steps: max_train_steps,
            max_eval_steps: max_eval_steps
          }}}
    end
  end

  @doc "The limit that applies to what the model is doing right now."
  @spec call(map(), Monty.Experiment.RecognitionPolicy.RecognitionCounter.t(), map()) ::
          RecognitionResult.t()
  def call(%{is_exploring: true}, counter, state) do
    is_done = counter.exploring_steps >= state.num_exploring_steps
    %RecognitionResult{is_done: is_done, time_out_lms: is_done}
  end

  def call(_model, %{mode: :train} = counter, state) do
    is_done = counter.matching_steps >= state.max_train_steps

    %RecognitionResult{
      is_done: is_done,
      time_out_lms: is_done,
      start_exploring: counter.matching_steps >= state.min_train_steps
    }
  end

  def call(_model, %{mode: :eval} = counter, state) do
    is_done = counter.matching_steps >= state.max_eval_steps
    %RecognitionResult{is_done: is_done, time_out_lms: is_done}
  end
end
