defmodule Monty.Experiment.RecognitionPolicy.NaiveScan do
  @moduledoc """
  Done when a naive scan's spiral has completed.

  Mirrors `tbp/monty/experiment/recognition_policy.py::NaiveScan`. The scan moves
  in fixed steps and turns until it has swept ninety degrees, so the number of
  steps in the spiral is arithmetic on the step size and nothing else:

      k = ceil(90 / fixed_amount)
      step_limit = k * (k - 1) + 1

  which is 1, 73, 307 and 8011 for step sizes of 90, 10, 5 and 1 — Monty's own
  numbers, and the reason this policy exists rather than a plain step ceiling.
  """

  alias Monty.Experiment.RecognitionPolicy.RecognitionResult

  @doc """
  A policy whose ceiling is the spiral's own length.

  Monty raises `ValueError` for a step size that is not positive; here that is
  `{:error, message}` with Monty's own words.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    fixed_amount = Keyword.fetch!(options, :fixed_amount)

    if fixed_amount <= 0 do
      {:error, "fixed_amount must be positive"}
    else
      {:ok, {__MODULE__, %{step_limit: step_limit(fixed_amount)}}}
    end
  end

  @doc "Done when the spiral is complete."
  @spec call(map(), Monty.Experiment.RecognitionPolicy.RecognitionCounter.t(), map()) ::
          RecognitionResult.t()
  def call(_model, counter, %{step_limit: step_limit}) do
    %RecognitionResult{is_done: counter.step >= step_limit}
  end

  @doc "How many steps a spiral of this step size takes, as Monty computes it."
  @spec step_limit(pos_integer()) :: pos_integer()
  def step_limit(fixed_amount) do
    k = ceil(90 / fixed_amount)
    k * (k - 1) + 1
  end
end
