defmodule Monty.Experiment.RecognitionPolicy.MinimumLMs do
  @moduledoc """
  Done once enough learning modules have concluded, whatever they concluded.

  Mirrors `tbp/monty/experiment/recognition_policy.py::MinimumLMs`. It reads only
  *whether* a module concluded — `:match`, `:no_match` or `:time_out` all count —
  which is what makes it usable when the question is "has every module made up
  its mind" rather than "did we recognise the object".
  """

  alias Monty.Experiment.RecognitionPolicy.RecognitionResult

  @doc """
  A policy satisfied by `:min_lms` concluded modules.

  Monty raises `ValueError` for a minimum that is not positive; here that is
  `{:error, message}` with Monty's own words.
  """
  @spec new(keyword()) :: {:ok, {module(), map()}} | {:error, String.t()}
  def new(options) do
    min_lms = Keyword.fetch!(options, :min_lms)

    if min_lms <= 0 do
      {:error, "min_lms must be positive"}
    else
      {:ok, {__MODULE__, %{min_lms: min_lms}}}
    end
  end

  @doc "Done when enough modules have concluded, however they concluded."
  @spec call(map(), Monty.Experiment.RecognitionPolicy.RecognitionCounter.t(), map()) ::
          RecognitionResult.t()
  def call(model, _counter, %{min_lms: min_lms}) do
    concluded = Enum.count(model.conclusions, &(&1 != nil))

    %RecognitionResult{is_done: concluded >= min_lms}
  end
end
