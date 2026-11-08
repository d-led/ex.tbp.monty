defmodule Monty.Frameworks.Models.EvidenceMatching.HypothesesDisplacer.HypothesisDisplacerTelemetry do
  @moduledoc """
  What a displacing step reports about itself.

  Mirrors
  `tbp/monty/frameworks/models/evidence_matching/hypotheses_displacer.py::HypothesisDisplacerTelemetry`.

  `mlh_prediction_error` is how wrong the most likely hypothesis was about this
  observation, in `[0, 1]`: 0 when its evidence was the best a perfect match
  could give, 1 when it was the worst possible. It is `nil` before the first
  evidence update — nothing has been predicted yet, and zero would claim a
  perfect prediction that never happened.
  """

  @enforce_keys [:mlh_prediction_error]
  defstruct [:mlh_prediction_error]

  @type t :: %__MODULE__{mlh_prediction_error: float() | nil}
end
