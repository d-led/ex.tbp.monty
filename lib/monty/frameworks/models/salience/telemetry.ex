defmodule Monty.Frameworks.Models.Salience.Telemetry do
  @moduledoc """
  What a salience module writes down about the views it judged.

  Mirrors `tbp/monty/frameworks/models/salience/telemetry.py`, whose three
  classes are the interface (`...Telemetry.SalienceSMTelemetry`), the recorder
  that records nothing (`...Telemetry.NoopSalienceSMTelemetry`) and the one that
  records everything (`...Telemetry.DetailedSalienceSMTelemetry`).

  A salience module's output is a *choice* — which of a view's pixels are worth
  looking at — and a choice is not reproducible from the percepts alone. What
  the strategy scored, what the inhibition suppressed and what the segmentation
  proposed are recorded here so a run can be read afterwards.
  """
end
