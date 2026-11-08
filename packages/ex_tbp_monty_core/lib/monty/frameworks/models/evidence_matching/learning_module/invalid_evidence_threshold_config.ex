defmodule Monty.Frameworks.Models.EvidenceMatching.LearningModule.InvalidEvidenceThresholdConfig do
  @moduledoc """
  An evidence update threshold setting that Monty does not define.

  Mirrors `...evidence_matching/learning_module.py::InvalidEvidenceThresholdConfig`,
  a `ValueError` raised when `evidence_threshold_config` is not one of the
  documented forms.

  Here it is an exception used as the reason of an `{:error, _}` result, so an
  experiment with a mistyped threshold — `"avg"` instead of `"mean"`, or
  `"120%"` — fails where the learning module is built, with a message that
  names the value, instead of producing a threshold that is quietly wrong.
  """

  defexception [:config]

  @type t :: %__MODULE__{config: term()}

  @impl true
  def message(%{config: config}) do
    "evidence_threshold_config #{inspect(config)} is not one of " <>
      "[number, '[number]%', \"mean\", \"median\", \"all\", \"x_percent_threshold\"]"
  end
end
