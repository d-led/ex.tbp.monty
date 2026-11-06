defmodule Monty.Frameworks.Models.Mixins.NoResetEvidence.HypothesesUpdaterGraphTelemetry do
  @moduledoc """
  One graph's hypotheses, as the updater left them: what a chart draws.

  Mirrors `frameworks/models/mixins/no_reset_evidence.py::HypothesesUpdaterGraphTelemetry`,
  the dataclass Monty's pyview dashboard reads. Four arrays and the updater's
  own telemetry, one entry per hypothesis of one graph:

    * `evidence` — what each hypothesis is worth;
    * `locations` — where each one puts the object, in metres;
    * `rotations` — how each one is turned, as Euler angles in degrees in
      Monty's `xyz` order;
    * `pose_errors` — how far each hypothesis' rotation is from the target's,
      in radians, which is the number a recognition's accuracy is measured by;
    * `hypotheses_updater` — whatever the updater said about this graph, passed
      through rather than interpreted.

  Monty keeps these as numpy arrays; here they are lists, and
  `Monty.Frameworks.Models.Buffer.BufferEncoder` writes a struct of this shape
  as a JSON object the way Monty's own encoder writes a dataclass.
  """

  @enforce_keys [:hypotheses_updater, :evidence, :rotations, :locations, :pose_errors]
  defstruct [:hypotheses_updater, :evidence, :rotations, :locations, :pose_errors]

  @type t :: %__MODULE__{
          hypotheses_updater: map(),
          evidence: [float()],
          rotations: [[float()]],
          locations: [[float()]],
          pose_errors: [float()]
        }

  @doc """
  The telemetry of a graph that has no hypotheses.

  Monty builds the same record with four empty arrays — a graph with nothing
  believed still has a row in a log, and leaving it out would make "no
  hypotheses" look like "not reported".
  """
  @spec empty(map()) :: t()
  def empty(graph_telemetry) do
    %__MODULE__{
      hypotheses_updater: graph_telemetry,
      evidence: [],
      rotations: [],
      locations: [],
      pose_errors: []
    }
  end
end
