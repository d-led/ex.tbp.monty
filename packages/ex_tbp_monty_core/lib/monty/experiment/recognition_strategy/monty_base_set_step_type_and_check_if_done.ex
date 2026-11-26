defmodule Monty.Experiment.RecognitionStrategy.MontyBaseSetStepTypeAndCheckIfDone do
  @moduledoc """
  `MontyBase`'s own step rule: run until the minimum, then change phase or stop.

  Mirrors
  `tbp/monty/experiment/recognition_strategy.py::MontyBaseSetStepTypeAndCheckIfDone`.
  There is no match criterion here — a bare `MontyBase` has no notion of
  recognition, so the only thing that ends a phase is its step count:

    * an exploratory phase ends after `num_exploratory_steps`;
    * a training matching phase switches to exploring after `min_train_steps`;
    * an evaluation matching phase ends after `min_eval_steps`.

  Monty's comparison is strict (`> `), and the counts are the steps a module
  processed, which is what `RecognitionContext` carries.

  Monty's own tests use this class, and its docstring says so; no shipped
  experiment does (`mix monty.target_census` prints who names what).
  """

  alias Monty.Experiment.RecognitionStrategy.RecognitionResult

  @options [:min_train_steps, :min_eval_steps, :num_exploratory_steps]

  @doc """
  The policy with its three minimums.

  Monty's constructor takes all three; one that is missing is refused rather
  than defaulted.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    case Keyword.take(options, @options) do
      taken when length(taken) == length(@options) ->
        {:ok, {__MODULE__, Map.new(taken)}}

      _missing ->
        {:error, "a step-type policy needs #{Enum.join(@options, ", ")}"}
    end
  end

  @doc "The decision, from what the model is doing and how far the phase has run."
  @spec call(map(), Monty.Experiment.RecognitionStrategy.RecognitionContext.t(), map()) ::
          RecognitionResult.t()
  def call(model, counter, state) do
    if exceeded_min_steps?(model, counter, state),
      do: decision(model, counter),
      else: %RecognitionResult{}
  end

  defp decision(%{is_exploring: true}, _counter), do: %RecognitionResult{is_done: true}
  defp decision(_model, %{mode: :train}), do: %RecognitionResult{start_exploring: true}
  defp decision(_model, %{mode: :eval}), do: %RecognitionResult{is_done: true}

  defp exceeded_min_steps?(%{is_exploring: true} = _model, counter, state),
    do: counter.exploring_steps > state.num_exploratory_steps

  defp exceeded_min_steps?(_model, %{mode: :train} = counter, state),
    do: counter.matching_steps > state.min_train_steps

  defp exceeded_min_steps?(_model, %{mode: :eval} = counter, state),
    do: counter.matching_steps > state.min_eval_steps
end
