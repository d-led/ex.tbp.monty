defmodule Monty.Experiment.RecognitionPolicy.MaxTotalSteps do
  @moduledoc """
  Done at a hard step ceiling, and every lagging module timed out with it.

  Mirrors `tbp/monty/experiment/recognition_policy.py::MaxTotalSteps`. The
  ceiling counts *every* step, not matching ones, so it is what stops an episode
  that is spinning without ever perceiving anything.
  """

  alias Monty.Experiment.RecognitionPolicy.RecognitionResult

  @doc """
  A policy that ends the episode at `:max_total_steps` steps.

  Monty raises `ValueError` for a ceiling that is not positive; here that is
  `{:error, message}` with Monty's own words.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    max_total_steps = Keyword.fetch!(options, :max_total_steps)

    if max_total_steps <= 0 do
      {:error, "max_total_steps must be positive"}
    else
      {:ok, {__MODULE__, %{max_total_steps: max_total_steps}}}
    end
  end

  @doc "Done at the ceiling; a ceiling reached is also a timeout for the modules."
  @spec call(map(), Monty.Experiment.RecognitionPolicy.RecognitionCounter.t(), map()) ::
          RecognitionResult.t()
  def call(_model, counter, %{max_total_steps: max_total_steps}) do
    is_done = counter.step >= max_total_steps
    %RecognitionResult{is_done: is_done, time_out_lms: is_done}
  end
end
